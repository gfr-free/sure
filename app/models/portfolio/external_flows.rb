# Sorts the cash entries of investment accounts into what a return calculation
# needs to tell apart:
#
#   external  money the owner moved into or out of the account (deposits,
#             withdrawals, transfers, and any entry without a label)
#   income    dividends and interest, earned by the investments
#   cost      fees and taxes, paid by the investments
#
# Buys, sells, sweeps, reinvestments and currency exchanges only move value
# inside the account and are left out. Every trade is internal except those
# labelled as income or cost (dividend, interest and fee trades).
#
# The balance of an investment account already contains all of these, so a
# return is "change in value minus external flows": income raises it and costs
# lower it without being a flow of their own.
#
# Amounts are converted to the account's currency the way the balance
# calculator converts them (a custom rate on the entry first, else the day's
# rate), so the flows match the balances they are compared with. Entries that
# cannot be converted are left out, as the balance calculator leaves them out.
class Portfolio::ExternalFlows
  INTERNAL_LABELS = [ "Buy", "Sell", "Sweep In", "Sweep Out", "Reinvestment", "Exchange" ].freeze
  INCOME_LABELS = %w[Dividend Interest].freeze
  COST_LABELS = %w[Fee Tax].freeze

  # amount is in the account's currency and signed from the owner's point of
  # view: a deposit, a dividend and a fee are all positive.
  Flow = Data.define(:account_id, :date, :kind, :amount)

  def self.classify(entryable_type:, label:)
    return :income if INCOME_LABELS.include?(label)
    return :cost if COST_LABELS.include?(label)
    return nil if entryable_type == "Trade" || INTERNAL_LABELS.include?(label)

    :external
  end

  def initialize(accounts, start_date:, end_date:)
    @accounts = accounts
    @start_date = start_date
    @end_date = end_date
    @rates_by_currency = {}
  end

  def flows
    @flows ||= begin
      currencies = @accounts.to_h { |account| [ account.id, account.currency ] }

      entry_rows.filter_map do |account_id, date, amount, currency, entryable_type, label, custom_rate|
        kind = self.class.classify(entryable_type: entryable_type, label: label)
        next if kind.nil?

        account_currency = currencies.fetch(account_id)
        converted = convert(amount.to_d, from: currency, to: account_currency, date: date, custom_rate: custom_rate)
        next if converted.nil?

        # Entry amounts are positive when money leaves the account.
        owner_amount = kind == :cost ? converted : -converted
        Flow.new(account_id: account_id, date: date, kind: kind, amount: owner_amount)
      end
    end
  end

  private
    def entry_rows
      return [] if @accounts.empty?

      Entry
        .where(account_id: @accounts.map(&:id), date: @start_date..@end_date, entryable_type: %w[Transaction Trade])
        .excluding_pending
        .excluding_split_parents
        .joins("LEFT JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .joins("LEFT JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
        .pluck(
          :account_id,
          :date,
          :amount,
          :currency,
          :entryable_type,
          Arel.sql("COALESCE(transactions.investment_activity_label, trades.investment_activity_label)"),
          Arel.sql("COALESCE(transactions.extra ->> 'exchange_rate', trades.extra ->> 'exchange_rate')")
        )
    end

    def convert(amount, from:, to:, date:, custom_rate:)
      return amount if from == to

      rate = custom_rate.presence&.to_d
      rate = nil unless rate&.positive?
      rate ||= rates_to(to).rate(from, date)
      return nil if rate.nil?

      amount * rate
    end

    def rates_to(currency)
      @rates_by_currency[currency] ||= Portfolio::DailyRates.new(to: currency, start_date: @start_date, end_date: @end_date)
    end
end
