# Exchange rates for one date range, loaded once per currency pair and looked
# up per day. Portfolio::Performance converts every account value and flow on
# every day of a period, which would be one query per day through
# ExchangeRate.find_or_fetch_rate.
#
# A day without a stored rate (weekends, provider gaps) takes the most recent
# earlier rate; days before the first stored rate take that first rate. A pair
# with no stored rate at all returns nil rather than 1, so callers can leave the
# amount out and say so instead of silently mixing currencies.
class Portfolio::DailyRates
  # How far before the range to look for a rate to carry into its first days.
  LOOKBACK_DAYS = 14

  attr_reader :to, :start_date, :end_date

  def initialize(to:, start_date:, end_date:)
    @to = to
    @start_date = start_date
    @end_date = end_date
    @pairs = {}
  end

  def rate(from, date)
    return BigDecimal("1") if from == to

    rates = rates_for(from)
    return nil if rates.empty?

    index = rates.bsearch_index { |rate_date, _| rate_date > date }
    position = index.nil? ? rates.size - 1 : index - 1
    position = 0 if position.negative?
    rates[position].last
  end

  # The rate at the end of the range, used to convert a whole period at one
  # fixed rate so that currency movements drop out of the result.
  def closing_rate(from)
    rate(from, end_date)
  end

  def available?(from)
    from == to || rates_for(from).any?
  end

  private
    # [[date, rate], ...] sorted by date.
    def rates_for(from)
      @pairs[from] ||= begin
        rows = ExchangeRate
          .where(from_currency: from, to_currency: to, date: (start_date - LOOKBACK_DAYS)..end_date)
          .where("rate > 0")
          .order(:date)
          .pluck(:date, :rate)

        rows = latest_before_range(from) if rows.empty?
        rows.map { |date, rate| [ date, rate.to_d ] }
      end
    end

    # A pair whose stored rates all predate the range still has a usable rate:
    # the last one known.
    def latest_before_range(from)
      ExchangeRate
        .where(from_currency: from, to_currency: to)
        .where(date: ...(start_date - LOOKBACK_DAYS))
        .where("rate > 0")
        .order(date: :desc)
        .limit(1)
        .pluck(:date, :rate)
    end
end
