# Decides, for every column of entries and transactions and for every key read
# from transactions.extra, what a split part takes from its parent:
#
# - INHERITED: copied from the parent, because the part is the same money on the
#   same account and day (currency, the parent's own exchange rate, kind, ...).
# - PER_PART: set by each split row (name, amount, category, ...).
# - NOT_INHERITED: left at the default on purpose, such as ids, timestamps,
#   provider references that must stay unique, and how the parent was edited.
#
# EntrySplitInheritanceTest fails when a column or extra key is in no group, so
# a new field needs a decision about split parts before it ships.
class Entry::SplitInheritance
  ENTRY_COLUMNS = {
    inherited: %w[account_id currency date import_id import_locked],
    per_part: %w[amount excluded name notes],
    not_inherited: %w[
      created_at entryable_id entryable_type external_id id idempotency_key
      locked_attributes parent_entry_id plaid_id reconciled_at
      reconciled_by_statement_id reconciled_status source updated_at user_modified
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
    inherited: %w[exchange_rate exchange_rate_invalid security security_id],
    # Provider payloads describe the bank's row (a pending flag there would make
    # the part pending), goal pledges are unique per transaction, and the
    # matching and merge bookkeeping is about the parent.
    not_inherited: %w[
      auto_claimed_pending_ids binance coinspot demo_financekit_activity_version
      financekit goal kraken manual_merge monobank plaid potential_posted_match
      provider_name redbark simplefin wise
    ]
  }.freeze

  def initialize(parent)
    @parent = parent
  end

  def entry_attributes
    @parent.attributes.slice(*ENTRY_COLUMNS[:inherited])
  end

  def transaction_attributes
    transaction = @parent.entryable
    return {} unless transaction.is_a?(Transaction)

    attributes = transaction.attributes.slice(*TRANSACTION_COLUMNS[:inherited])
    extra = transaction.extra.is_a?(Hash) ? transaction.extra.slice(*EXTRA_KEYS[:inherited]) : {}
    attributes["extra"] = extra if extra.any?
    attributes
  end
end
