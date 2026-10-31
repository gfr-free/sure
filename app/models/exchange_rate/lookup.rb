# Converts many amounts at their own dates with one query, so a list view
# doesn't look up a rate per row. It reads cached rates only and never calls
# the provider: a page render shouldn't wait on the network, and a missing
# rate is reported as nil so the caller can say so instead of guessing 1:1.
class ExchangeRate::Lookup
  attr_reader :to

  def initialize(currencies:, dates:, to:)
    @to = to
    @currencies = currencies.compact.uniq - [ to ]
    @dates = dates.compact.uniq
  end

  # Nearest cached rate on or before `date`, within the same lookback
  # window `find_or_fetch_rate` uses.
  def rate(from:, date:)
    return 1 if from == to

    candidates = rates_by_currency[from]
    return nil if candidates.blank?

    after = candidates.bsearch_index { |rate_date, _| rate_date > date } || candidates.size
    return nil if after.zero?

    rate_date, value = candidates[after - 1]
    value if rate_date >= date - ExchangeRate::NEAREST_RATE_LOOKBACK_DAYS
  end

  def convert(money, date:)
    value = rate(from: money.currency.iso_code, date: date)
    Money.new(money.amount * value, to) if value
  end

  private
    attr_reader :currencies, :dates

    # { "USD" => [[date, rate], ...] } sorted by date for the binary search.
    def rates_by_currency
      @rates_by_currency ||= begin
        if currencies.empty? || dates.empty?
          {}
        else
          ExchangeRate
            .where(from_currency: currencies, to_currency: to)
            .where(date: (dates.min - ExchangeRate::NEAREST_RATE_LOOKBACK_DAYS)..dates.max)
            .where("rate > 0")
            .order(:date)
            .pluck(:from_currency, :date, :rate)
            .group_by(&:first)
            .transform_values { |rows| rows.map { |_, date, rate| [ date, rate ] } }
        end
      end
    end
end
