# Decides, for every column of entries and transactions and for every key read
# from transactions.extra, what a split part takes from its parent:
#
# - INHERITED: copied from the parent, because the part is the same money on the
#   same account and day (currency, the parent's own exchange rate, kind, ...).
# - PER_PART: set by each split row (name, amount, category, ...).
# - NOT_INHERITED: left at the default on purpose, such as ids, timestamps,
#   provider references that must stay unique, and how the parent was edited.
#
# Entry::SplitInheritanceTest fails when a column or extra key is in no group, so
# a new field needs a decision about split parts before it ships.
class Entry::SplitInheritance
  ENTRY_COLUMNS = {
    # The reconciliation (manual status, or the statement that matched the
    # parent) covers the same money, so the parts don't start over as open.
    inherited: %w[
      account_id currency date import_id import_locked
      reconciled_at reconciled_by_statement_id reconciled_status
    ],
    per_part: %w[amount excluded name notes],
    not_inherited: %w[
      created_at entryable_id entryable_type external_id id idempotency_key
      locked_attributes parent_entry_id plaid_id source updated_at user_modified
    ]
  }.freeze

  # extra is copied key by key, see EXTRA_KEYS.
  TRANSACTION_COLUMNS = {
    inherited: %w[investment_activity_label kind],
    per_part: %w[category_id merchant_id],
    by_key: %w[extra],
    not_inherited: %w[created_at external_id id locked_attributes provider_entry_reference transfer_id updated_at]
  }.freeze

  EXTRA_KEYS = {
    # The parent's own exchange rate converts the parts the same way, and the
    # activity's security belongs to every part of it.
    inherited: %w[exchange_rate security security_id],
    # Provider payloads describe the bank's row (a pending flag there would make
    # the part pending), goal pledges are unique per transaction, and the
    # matching and merge bookkeeping is about the parent.
    # A rate the parent failed validation with is not copied: the part would
    # fail it too and roll back the whole split.
    not_inherited: %w[
      akahu auto_claimed_pending_ids auto_excluded_stale_pending binance coinspot
      demo_financekit_activity_version enable_banking exchange_rate_invalid
      financekit goal kraken lunchflow manual_merge mercury monarch monobank plaid
      potential_posted_match provider_name redbark simplefin superseded_external_ids
      up wise
    ]
  }.freeze

  def initialize(parent)
    @parent = parent
  end

  def entry_attributes
    @parent.attributes.slice(*ENTRY_COLUMNS[:inherited]).symbolize_keys
  end

  def transaction_attributes
    transaction = @parent.entryable
    return {} unless transaction.is_a?(Transaction)

    attributes = transaction.attributes.slice(*TRANSACTION_COLUMNS[:inherited]).symbolize_keys
    extra = inherited_extra(transaction.extra)
    attributes[:extra] = extra if extra.any?
    attributes
  end

  private
    def inherited_extra(extra)
      return {} unless extra.is_a?(Hash)

      inherited = extra.slice(*EXTRA_KEYS[:inherited])
      inherited = inherited.except("exchange_rate") if extra["exchange_rate_invalid"]
      inherited
    end
end
