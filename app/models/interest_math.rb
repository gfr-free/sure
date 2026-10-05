# Day-by-day interest arithmetic, free of any account or database access (like
# Loan::AmortizationMath), so it can be tested with fixed examples.
#
# Rates are nominal, in percent per year. Interest accrues on each day's
# closing balance. The day count convention is fixed per currency (decision
# E18): EUR uses the German 30E/360 method, everything else actual/365.
module InterestMath
  DAY_COUNTS = %w[thirty_360 act_365].freeze

  module_function

  def day_count_for(currency)
    currency.to_s.upcase == "EUR" ? "thirty_360" : "act_365"
  end

  def days_in_year(day_count)
    day_count == "thirty_360" ? 360 : 365
  end

  # How many interest days a calendar day counts for. Under 30E/360 every month
  # has 30 days: the 31st counts for nothing and the last day of February makes
  # up the missing days, so a full month always accrues 30 days and a full
  # year 360.
  def day_weight(date, day_count)
    return 1 unless day_count == "thirty_360"
    return 0 if date.day == 31
    return 30 - date.day + 1 if date.month == 2 && date == date.end_of_month

    1
  end

  # Interest for one day on `balance` at `rate` percent per year.
  def daily_interest(balance, rate, date, day_count)
    return BigDecimal("0") if rate.nil? || balance.nil? || rate.zero? || balance.zero?

    BigDecimal(balance.to_s) * BigDecimal(rate.to_s) / 100 * day_weight(date, day_count) / days_in_year(day_count)
  end

  # Interest from `from` through `to`, both inclusive. `balance_on` returns the
  # day's closing balance, `rate_on` the rate for a day and balance.
  def accrue(from:, to:, day_count:, balance_on:, rate_on:)
    return BigDecimal("0") if from > to

    (from..to).sum(BigDecimal("0")) do |date|
      balance = balance_on.call(date)
      daily_interest(balance, rate_on.call(date, balance), date, day_count)
    end
  end
end
