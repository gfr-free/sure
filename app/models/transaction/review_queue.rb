# The transactions that still need attention, grouped into review kinds, for
# the Review page. Built on Transaction::Search, so every transaction filter
# narrows the counts and lists too. Read-only: the page links each row to the
# drawer and bulk tools that already fix it.
class Transaction::ReviewQueue
  KINDS = %w[uncategorized no_merchant long_pending possible_duplicate transfer_suggestion].freeze

  # A pending transaction older than this counts as "pending for a long time".
  LONG_PENDING_AFTER = 5.days

  # Badge count for the Review nav entry: the uncategorized transactions the
  # viewer can still categorize, counted like the "Without category" tile.
  # Memoized per request and cached until entries, accounts or shares change.
  def self.badge_count
    Current.review_badge_count ||= Rails.cache.fetch(badge_count_cache_key) do
      Current.annotatable_entries
        .uncategorized_transactions
        .where.not(entryable_id: Transfer.select(:inflow_transaction_id))
        .count
    end
  end

  def self.badge_count_cache_key
    "review_badge_count/v1/#{Current.family.id}/#{Current.user.id}/" \
      "#{Current.family.entries_version}/#{Current.family.accounts_status_version}/#{Current.account_share_version}"
  end

  def initialize(family, user:, filters: {})
    @family = family
    @user = user
    @filters = filters
  end

  # One COUNT per kind. Kept as separate relations (rather than one query with
  # FILTER clauses) so every condition stays a plain, bound where clause.
  def counts
    @counts ||= KINDS.index_with { |kind| transactions_for(kind).count }
  end

  def transactions_for(kind)
    case kind
    when "uncategorized"
      # Entry.uncategorized_transactions, minus the inflow leg of a transfer:
      # its category lives on the outflow leg, and the list shows a transfer
      # once, on that leg.
      base_scope
        .where(category_id: nil)
        .where.not(kind: Transaction::UNCATEGORIZED_EXCLUDED_KINDS)
        .where.not(id: Transfer.select(:inflow_transaction_id))
    when "no_merchant"
      # Transfers and loan or investment payments have no merchant by design.
      base_scope.where(merchant_id: nil, kind: "standard")
    when "long_pending"
      base_scope.merge(Transaction.pending).where(entries: { date: ...(Date.current - LONG_PENDING_AFTER) })
    when "possible_duplicate"
      base_scope
        # Mirrors Transaction#has_potential_duplicate?: a non-empty object
        # whose "dismissed" is not the JSON boolean true.
        .where("jsonb_typeof(transactions.extra -> 'potential_posted_match') = 'object'")
        .where("transactions.extra -> 'potential_posted_match' <> '{}'::jsonb")
        .where("(transactions.extra -> 'potential_posted_match' -> 'dismissed') IS DISTINCT FROM 'true'::jsonb")
    when "transfer_suggestion"
      # One row per suggested pair: the outflow leg, and only when the
      # viewer can see the inflow leg too (as on the Auto Matches page).
      base_scope.where(id: suggested_transfer_outflow_ids)
    else
      raise ArgumentError, "unknown review kind: #{kind}"
    end
  end

  private
    attr_reader :family, :user, :filters

    def base_scope
      @base_scope ||= Transaction::Search.new(family, filters: filters, accessible_account_ids: accessible_account_ids)
        .transactions_scope
        .where(entries: { excluded: false })
    end

    def accessible_account_ids
      @accessible_account_ids ||= user.accessible_accounts.pluck(:id)
    end

    def suggested_transfer_outflow_ids
      Transfer.pending
        .joins(inflow_transaction: :entry)
        .where(entries: { account_id: accessible_account_ids })
        .select(:outflow_transaction_id)
    end
end
