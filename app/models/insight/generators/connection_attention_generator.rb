# Flags provider connections that stopped bringing in data, so the family
# hears about it instead of noticing days later that transactions are missing:
#
# - reconnect: the connection can't import until someone signs in again
#   (the same rule the account page uses, ProviderConnectionStatus.requires_update?)
# - failing: its syncs keep failing and nothing went through for FAILING_AFTER
# - expiring: an Enable Banking consent ends within EXPIRY_WARNING
#
# Each problem is one insight per connection and reason, and one problem is one
# episode: GenerateInsightsJob expires the row once the problem clears, even if
# it was acknowledged (Insight::EPISODIC_TYPES), so a problem that returns
# notifies again. While it lasts, metadata keeps the day it was first
# detected, and a `reminder` flag turns on once REMIND_AFTER later, which
# notifies a second time. Nothing else in metadata moves while the problem
# lasts, so a sync that completes in between does not notify again.
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
  REMINDING_REASONS = %w[reconnect failing].freeze

  def generate
    connections = ProviderConnectionStatus::PROVIDERS.flat_map do |provider|
      family.public_send(provider[:association]).to_a.map { |item| [ item, provider ] }
    end
    connections.reject! { |item, _| item.try(:scheduled_for_deletion?) == true }
    return [] if connections.empty?

    items = connections.map(&:first)
    terminal_syncs = latest_syncs(items, Sync.where(status: %w[completed failed stale]))
    completed_syncs = latest_syncs(items, Sync.completed)
    ongoing = family.insights.where(insight_type: TYPE).where.not(status: :expired).index_by(&:dedup_key)

    connections.filter_map do |item, provider|
      account_ids = linked_account_ids(item, provider)
      next if account_ids.empty?

      key = [ item.class.name, item.id ]
      problem = detect_problem(item, terminal_syncs[key], completed_syncs[key])
      build(item, provider, problem, account_ids, ongoing) if problem
    end
  end

  private
    Problem = Data.define(:reason, :last_success_at, :expires_at)

    def detect_problem(item, latest_terminal, latest_completed)
      last_success_at = latest_completed&.completed_at

      if ProviderConnectionStatus.requires_update?(item, latest_sync: latest_terminal)
        return Problem.new(reason: "reconnect", last_success_at: last_success_at, expires_at: nil)
      end

      if latest_terminal && (latest_terminal.failed? || latest_terminal.stale?) &&
         (last_success_at || item.created_at) <= FAILING_AFTER.ago
        return Problem.new(reason: "failing", last_success_at: last_success_at, expires_at: nil)
      end

      expiring_problem(item)
    end

    # Enable Banking is the one provider whose consent end is known ahead of
    # time and lasts long enough for a week's notice to mean something.
    def expiring_problem(item)
      return unless item.is_a?(EnableBankingItem)

      expires_at = item.session_expires_at
      return unless expires_at && expires_at > Time.current && expires_at <= EXPIRY_WARNING.from_now

      Problem.new(reason: "expiring", last_success_at: nil, expires_at: expires_at)
    end

    def build(item, provider, problem, account_ids, ongoing)
      provider_name = item.try(:institution_display_name).presence || item.try(:name).presence || provider[:key].humanize
      dedup_key = "#{TYPE}:#{item.class.name}:#{item.id}:#{problem.reason}"
      detected_on = detected_on(ongoing[dedup_key])
      expires_on = problem.expires_at&.to_date

      metadata = {
        connection_type: item.class.name,
        connection_id: item.id,
        reason: problem.reason,
        detected_on: detected_on.iso8601,
        reminder: problem.reason.in?(REMINDING_REASONS) && detected_on <= REMIND_AFTER.ago.to_date,
        account_ids: account_ids
      }
      metadata[:expires_on] = expires_on.iso8601 if expires_on

      facts = { provider: provider_name }
      # "No new data since" reads from the last sync that went through.
      facts[:since] = I18n.l((problem.last_success_at || item.created_at).to_date, format: :long) if problem.reason == "failing"
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
        dedup_key: dedup_key
      )
    end

    # The day an ongoing problem was first reported, carried over from its row;
    # today for a new one.
    def detected_on(ongoing_insight)
      return Date.current unless ongoing_insight

      Date.iso8601(ongoing_insight.metadata["detected_on"].to_s)
    rescue Date::Error
      Date.current
    end

    # One query per lookup across every provider: DISTINCT ON keeps the newest
    # sync of each connection within the given scope.
    def latest_syncs(items, scope)
      Sync.for_syncables(items).merge(scope)
        .select("DISTINCT ON (syncable_type, syncable_id) syncs.*")
        .order("syncable_type, syncable_id, created_at DESC, id DESC")
        .index_by { |sync| [ sync.syncable_type, sync.syncable_id ] }
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
