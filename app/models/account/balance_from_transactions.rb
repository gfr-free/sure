# Lets a linked account keep its own balance: the provider's transactions are
# imported as usual, but the provider's balance is no longer used.
#
# Switching on records the day. The first sync after that takes the balance
# the account showed at the end of the day before as the start. Balances
# before that day stay as they are; from that day on, Balance::ForwardCalculator
# adds the imported transactions to the start, the way it does for a manual
# account. Nothing is written to the ledger, so switching off leaves nothing to
# clean up: the next sync goes back to the provider's balance.
module Account::BalanceFromTransactions
  extend ActiveSupport::Concern

  START_ATTRIBUTES = %i[
    balance_from_transactions_start_cash
    balance_from_transactions_start_non_cash
    balance_from_transactions_ledger_total
  ].freeze

  included do
    before_save :keep_calculated_balance, if: :calculates_balance_from_transactions?
  end

  # Investment and crypto accounts are valued from their holdings, not from
  # their transactions.
  def supports_balance_from_transactions?
    linked? && balance_type != :investment
  end

  def balance_from_transactions?
    balance_from_transactions_since.present?
  end
  alias_method :balance_from_transactions, :balance_from_transactions?

  def balance_from_transactions=(value)
    enable = ActiveModel::Type::Boolean.new.cast(value)
    return if enable == balance_from_transactions?
    return if enable && !supports_balance_from_transactions?

    self.balance_from_transactions_since = (Date.current if enable)
    START_ATTRIBUTES.each { |attr| self[attr] = nil }
  end

  # Only a linked account has a provider balance to leave out. An account
  # unlinked with the switch on is a manual account again, rebuilt from its
  # opening balance.
  def calculates_balance_from_transactions?
    balance_from_transactions? && linked?
  end

  # Whether this account's balances are rebuilt backwards from the provider's
  # current balance or forwards from a starting point.
  def balance_strategy
    linked? && !balance_from_transactions? ? :reverse : :forward
  end

  # Records the start on the first calculation after switching on. Called by
  # Balance::Materializer while it holds the account's row lock, so the rows it
  # reads are not being rewritten by another sync.
  #
  # The start is the end of the day before the switch. The ledger total is the
  # sum of the transactions dated before that day, as they stood: one dated
  # earlier that is imported, edited or removed later still changes the balance
  # from the switch on (Balance::ForwardCalculator), while the days before the
  # switch stay as they were.
  def record_balance_from_transactions_start!
    return unless calculates_balance_from_transactions?
    return unless balance_from_transactions_start_cash.nil?

    since = balance_from_transactions_since
    rows = balances.where(currency: currency)
    start_cash, start_non_cash =
      if (before = rows.where(date: ...since).order(date: :desc).first)
        [ before.end_cash_balance, before.end_non_cash_balance ]
      elsif (on = rows.find_by(date: since))
        [ on.start_cash_balance, on.start_non_cash_balance ]
      else
        [ cash_balance || 0, (balance || 0) - (cash_balance || 0) ]
      end

    update_columns(
      balance_from_transactions_start_cash: start_cash,
      balance_from_transactions_start_non_cash: start_non_cash,
      balance_from_transactions_ledger_total: ledger_total_before(since)
    )
  end

  # Sum of the settled transactions and trades dated before `date`, in the
  # account's currency, counted the way the balance calculation counts them.
  def ledger_total_before(date)
    Balance::SyncCache.new(self).entries
      .select { |entry| entry.date < date && (entry.transaction? || entry.trade?) }
      .sum(&:amount)
  end

  # Syncs the account after the switch changed. Switching on only rebuilds the
  # balances. Switching off goes back to the provider's balance, whose anchor
  # has stood still while the switch was on, so the provider items sync first
  # and anchor a fresh reading; each of them syncs the account when it is done.
  def sync_after_balance_switch_later
    items = balance_from_transactions? ? [] : provider_items
    return sync_later if items.empty?

    items.each do |item|
      next if item.syncing?

      item.is_a?(PlaidItem) ? item.sync_later_with_provider_refresh : item.sync_later
    end
  end

  # Lets Balance::Materializer store the balance it calculated.
  def writing_calculated_balance
    @writing_calculated_balance = true
    yield
  ensure
    @writing_calculated_balance = false
  end

  private
    def provider_items
      items = account_providers.filter_map { |account_provider| account_provider.adapter&.item }
      items << plaid_account.plaid_item if plaid_account
      items << simplefin_account.simplefin_item if simplefin_account
      items.compact.uniq
    end

    # Providers write their balance straight to the account on every sync. An
    # account that keeps its own balance keeps the calculated one instead.
    def keep_calculated_balance
      return if @writing_calculated_balance

      restore_attributes(%w[balance cash_balance] & changed)
    end
end
