# The transactions that still need attention, grouped into review kinds, for
# the Review page. Built on Transaction::Search, so every transaction filter
# narrows the counts and lists too. Read-only: the page links each row to the
# drawer and bulk tools that already fix it.
class Transaction::ReviewQueue
  KINDS = %w[uncategorized no_merchant flagged long_pending possible_duplicate transfer_suggestion].freeze

  # A pending transaction older than this counts as "pending for a long time".
  LONG_PENDING_AFTER = 5.days

  # Badge count for the Review nav entry: the transactions the viewer can
  # still work on that are flagged or uncategorized (and not marked reviewed),
  # each counted once, like the "Flagged" and "Without category" tiles.
  # One COUNT per request (memoized), not cached: a cache key that stays
  # correct here (entries, categories, account status and shares) costs more
  # queries on every page than the count itself.
  def self.badge_count
    Current.review_badge_count ||= Current.annotatable_entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(accounts: { status: %w[draft active] }, entries: { excluded: false })
      .where(<<~SQL.squish, excluded_kinds: Transaction::UNCATEGORIZED_EXCLUDED_KINDS)
        transactions.review_state = 'flagged' OR (
          transactions.review_state IS NULL
          AND transactions.category_id IS NULL
          AND transactions.kind NOT IN (:excluded_kinds)
          AND transactions.id NOT IN (SELECT inflow_transaction_id FROM transfers)
        )
      SQL
      .count
  end

  # Whether Quick Categorize has anything the viewer can categorize.
  def self.quick_categorize_available?
    Current.annotatable_entries.uncategorized_transactions.exists?
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
      # A transaction marked reviewed is done here, as below.
      base_scope
        .not_reviewed
        .where(category_id: nil)
        .where.not(kind: Transaction::UNCATEGORIZED_EXCLUDED_KINDS)
        .where.not(id: Transfer.select(:inflow_transaction_id))
    when "no_merchant"
      # Transfers and loan or investment payments have no merchant by design.
      base_scope.not_reviewed.where(merchant_id: nil, kind: "standard")
    when "flagged"
      base_scope.review_flagged
    when "long_pending"
      base_scope.not_reviewed.merge(Transaction.pending).where(entries: { date: ...(Date.current - LONG_PENDING_AFTER) })
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
