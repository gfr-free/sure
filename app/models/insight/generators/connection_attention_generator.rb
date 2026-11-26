# Flags provider connections that stopped bringing in data, so the family
# hears about it instead of noticing days later that transactions are missing:
#
# - reconnect: the connection can't import until someone signs in again
#   (the same rule the account page uses, ProviderConnectionStatus.requires_update?)
# - failing: its syncs keep failing and nothing went through for FAILING_AFTER
# - expiring: an Enable Banking consent ends within EXPIRY_WARNING
#
# Each problem is one insight per connection and reason. Its metadata carries
# the last successful sync as the episode anchor, so a connection that recovers
# and fails again notifies again even if the earlier insight was dismissed, and
# a `reminder` flag that turns on once after REMIND_AFTER, which notifies a
# second time while the problem lasts.
#
# A connection names its linked accounts in metadata account_ids instead of
# account_id. The feed shows the insight only while every active member can
# open all of them (Insight.about_shared_accounts); push goes to admins and to
# members who can open at least one (Insight#notifies?).
class Insight::Generators::ConnectionAttentionGenerator < Insight::Generator
  produces "connection_needs_attention"

  TYPE = "connection_needs_attention"
  FAILING_AFTER = 24.hours
  EXPIRY_WARNING = 7.days
  REMIND_AFTER = 3.days

  def generate
    connections = ProviderConnectionStatus::PROVIDERS.flat_map do |provider|
      family.public_send(provider[:association]).to_a.map { |item| [ item, provider ] }
    end
    connections.reject! { |item, _| item.try(:scheduled_for_deletion?) == true }
    return [] if connections.empty?

    items = connections.map(&:first)
    terminal_syncs = latest_syncs(items, Sync.where(status: %w[completed failed stale]))
    completed_syncs = latest_syncs(items, Sync.completed)

    connections.filter_map do |item, provider|
      account_ids = linked_account_ids(item, provider)
      next if account_ids.empty?

      key = [ item.class.name, item.id ]
      problem = detect_problem(item, terminal_syncs[key], completed_syncs[key])
      build(item, provider, problem, account_ids) if problem
    end
  end

  private
    Problem = Data.define(:reason, :last_success_at, :reportable_at, :expires_at)

    def detect_problem(item, latest_terminal, latest_completed)
      last_success_at = latest_completed&.completed_at

      if ProviderConnectionStatus.requires_update?(item, latest_sync: latest_terminal)
        started_at = first_failure_after(item, last_success_at) || last_success_at || item.created_at
        return Problem.new(reason: "reconnect", last_success_at: last_success_at, reportable_at: started_at, expires_at: nil)
      end

      if latest_terminal && (latest_terminal.failed? || latest_terminal.stale?)
        quiet_since = last_success_at || item.created_at
        return unless quiet_since <= FAILING_AFTER.ago

        first_failure = first_failure_after(item, last_success_at) || latest_terminal.created_at
        reportable_at = [ first_failure, quiet_since + FAILING_AFTER ].max
        return Problem.new(reason: "failing", last_success_at: last_success_at, reportable_at: reportable_at, expires_at: nil)
      end

      expiring_problem(item, last_success_at)
    end

    # Enable Banking is the one provider whose consent end is known ahead of
    # time and lasts long enough for a week's notice to mean something.
    def expiring_problem(item, last_success_at)
      return unless item.is_a?(EnableBankingItem)

      expires_at = item.session_expires_at
      return unless expires_at && expires_at > Time.current && expires_at <= EXPIRY_WARNING.from_now

      Problem.new(reason: "expiring", last_success_at: last_success_at, reportable_at: nil, expires_at: expires_at)
    end

    def build(item, provider, problem, account_ids)
      provider_name = item.try(:institution_display_name).presence || item.try(:name).presence || provider[:key].humanize
      expires_on = problem.expires_at&.to_date
      reminder = problem.reportable_at.present? && problem.reportable_at <= REMIND_AFTER.ago

      metadata = {
        connection_type: item.class.name,
        connection_id: item.id,
        reason: problem.reason,
        last_success_on: problem.last_success_at&.to_date&.iso8601,
        reminder: reminder,
        account_ids: account_ids
      }
      metadata[:expires_on] = expires_on.iso8601 if expires_on

      facts = { provider: provider_name }
      # "No new data since" reads from the last sync that went through.
      facts[:since] = I18n.l((problem.last_success_at || problem.reportable_at).to_date, format: :long) if problem.reason == "failing"
      facts[:expires_on] = I18n.l(expires_on, format: :long) if expires_on

      GeneratedInsight.new(
        insight_type: TYPE,
        priority: "high",
        title: I18n.t("insights.titles.connection_needs_attention.#{problem.reason}", provider: provider_name),
        template_key: "connection_needs_attention.#{problem.reason}",
        facts: facts,
        metadata: metadata,
        currency: family.currency,
        period_start: nil,
        period_end: nil,
        dedup_key: "#{TYPE}:#{item.class.name}:#{item.id}:#{problem.reason}"
      )
    end

    # One query per lookup across every provider: DISTINCT ON keeps the newest
    # sync of each connection within the given scope.
    def latest_syncs(items, scope)
      Sync.for_syncables(items).merge(scope)
        .select("DISTINCT ON (syncable_type, syncable_id) syncs.*")
        .order("syncable_type, syncable_id, created_at DESC, id DESC")
        .index_by { |sync| [ sync.syncable_type, sync.syncable_id ] }
    end

    def first_failure_after(item, time)
      failures = Sync.where(syncable: item, status: %w[failed stale])
      failures = failures.where("syncs.created_at > ?", time) if time
      failures.minimum(:created_at)
    end

    # Linked accounts the family still shows, through AccountProvider or the
    # legacy plaid_account / simplefin_account columns.
    def linked_account_ids(item, provider)
      provider_accounts = item.public_send(provider[:accounts])
      ids = AccountProvider.where(provider_type: provider_accounts.klass.name, provider_id: provider_accounts.select(:id)).pluck(:account_id)
      ids += Account.where(plaid_account_id: provider_accounts.select(:id)).pluck(:id) if item.is_a?(PlaidItem)
      ids += Account.where(simplefin_account_id: provider_accounts.select(:id)).pluck(:id) if item.is_a?(SimplefinItem)

      family.accounts.visible.where(id: ids.uniq).order(:id).pluck(:id)
    end
end
