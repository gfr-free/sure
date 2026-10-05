# What an account's interest terms (Account::Interest) produce: the interest
# accrued since the last payout, the next payout, payouts inside a window (for
# the account forecast) and the value of a locked account at maturity.
#
# Interest accrues day by day on the closing balance: the credit rate on a
# positive balance, the debit rate on an overdraft. Past days read the
# `balances` table, future days today's balance unless the caller passes a
# path (the account forecast passes its own). Interest is paid into the
# account itself (decision E18), so payouts after today are added to the
# balance that later days accrue on.
#
# Payouts fall on the last day of each period (month, quarter, half year,
# year). Paid at maturity, a term deposit capitalises once a year counted back
# from the maturity date, so a term of up to one year earns simple interest.
#
# Amounts are signed: positive is interest earned, negative interest charged.
class Account::InterestProjection
  Payout = Data.define(:date, :amount)

  # Upper bound for a simulation, so a release date decades out stays cheap.
  MAX_DAYS = 3660

  attr_reader :account, :as_of

  def initialize(account, as_of:)
    @account = account
    @as_of = as_of
  end

  def currency
    account.currency
  end

  def frequency
    account.effective_interest_payout_frequency
  end

  def day_count
    InterestMath.day_count_for(currency)
  end

  def credit_rate
    account.interest_rate_on(as_of, applies_to: "credit")
  end

  def debit_rate
    account.overdraft_interest_capable? ? account.interest_rate_on(as_of, applies_to: "debit") : nil
  end

  # Interest earned (or charged) since the last payout, today included.
  def accrued
    @accrued ||= begin
      start = accrual_start
      amount = start ? InterestMath.accrue(from: start, to: as_of, day_count: day_count,
                                           balance_on: method(:historical_balance), rate_on: method(:rate_on)) : 0
      money(amount)
    end
  end

  # The next payout on or after today, nil when the rhythm has none (a term
  # deposit paid at maturity without a release date).
  def next_payout
    return @next_payout if defined?(@next_payout)

    date = next_payout_date
    @next_payout = date && payouts_until(date).find { |payout| payout.date == date }
  end

  def next_payout_date
    period_end_on_or_after(as_of)
  end

  # Payouts dated after today, through `to`. `balance_on` gives the closing
  # balance for days after today, before any interest; the default keeps
  # today's balance.
  def payouts_between(to, balance_on: nil)
    payouts_until(to, balance_on: balance_on).select { |payout| payout.date > as_of }
  end

  # The maturity date of a locked account: its next release date.
  def maturity_date
    return nil unless account.liquidity == "locked"

    date = account.next_release_date(as_of)
    date if date && date >= as_of
  end

  # Balance plus the interest up to maturity, as released on that day.
  def value_at_maturity
    return @value_at_maturity if defined?(@value_at_maturity)

    maturity = maturity_date
    @value_at_maturity = if maturity.nil? || !account.interest_terms?
      nil
    else
      payouts = payouts_until(maturity)
      paid = payouts.select { |payout| payout.date >= as_of }.sum(BigDecimal("0")) { |payout| payout.amount.amount }
      paid += @pending_at_end
      account.balance_money + money(paid)
    end
  end

  private
    def money(amount)
      Money.new(BigDecimal(amount.to_s).round(2), currency)
    end

    def rate_on(date, balance)
      kind = balance.to_d.negative? ? "debit" : "credit"
      return nil if kind == "debit" && !account.overdraft_interest_capable?

      account.rate_entry_on(date, kind)&.rate
    end

    # The first day that has not been paid out yet: the day after the last
    # period end before today, and not before the first rate applies.
    def accrual_start
      first_rate = account.interest_rates.map(&:effective_from).min
      return nil if first_rate.nil? || first_rate > as_of

      last_end = period_end_before(as_of)
      [ last_end ? last_end + 1 : first_rate, first_rate ].max
    end

    # Runs the accrual from the accrual start through `to`, paying out at each
    # period end. Remembers what is still unpaid at `to`.
    def payouts_until(to, balance_on: nil)
      start = accrual_start
      @pending_at_end = BigDecimal("0")
      return [] if start.nil?

      to = [ to, as_of + MAX_DAYS ].min
      balance_on ||= ->(_date) { current_balance }
      payouts = []
      capitalised = BigDecimal("0")
      pending = BigDecimal("0")
      period_end = period_end_on_or_after(start)

      (start..to).each do |date|
        balance = date <= as_of ? historical_balance(date) : balance_on.call(date).to_d + capitalised
        pending += InterestMath.daily_interest(balance, rate_on(date, balance), date, day_count)

        next unless date == period_end

        payouts << Payout.new(date: date, amount: money(pending))
        capitalised += pending if date > as_of
        pending = BigDecimal("0")
        period_end = period_end_on_or_after(date + 1)
        break if period_end.nil?
      end

      @pending_at_end = pending
      payouts
    end

    def current_balance
      account.balance.to_d
    end

    # Closing balance on a past day from the `balances` table, carrying the
    # last known value over gaps. Today reads the account's current balance.
    def historical_balance(date)
      return current_balance if date >= as_of

      @balances_by_date ||= load_balances
      @balances_by_date.fetch(date) do
        known = @balances_by_date.keys.select { |day| day < date }.max
        known ? @balances_by_date[known] : BigDecimal("0")
      end
    end

    def load_balances
      start = accrual_start || as_of
      rows = account.balances.where(currency: currency, date: start..as_of).order(:date).pluck(:date, :end_balance)
      before = account.balances.where(currency: currency).where(date: ...start).order(date: :desc).limit(1).pluck(:date, :end_balance)
      (before + rows).to_h { |date, balance| [ date, balance.to_d ] }
    end

    def period_end_on_or_after(date)
      case frequency
      when "daily" then date
      when "monthly" then date.end_of_month
      when "quarterly" then date.end_of_quarter
      when "semiannual" then date.month <= 6 ? Date.new(date.year, 6, 30) : date.end_of_year
      when "annual" then date.end_of_year
      when "at_maturity"
        maturity_points.find { |point| point >= date } || date.end_of_year
      end
    end

    def period_end_before(date)
      case frequency
      when "daily" then date - 1
      when "monthly" then date.beginning_of_month - 1
      when "quarterly" then date.beginning_of_quarter - 1
      when "semiannual" then (date.month <= 6 ? date.beginning_of_year : Date.new(date.year, 7, 1)) - 1
      when "annual" then date.beginning_of_year - 1
      when "at_maturity"
        # Past the last known term end (a deposit that matured and did not
        # renew, or no release date at all) interest is counted yearly.
        candidates = maturity_points.select { |point| point < date }
        candidates << date.beginning_of_year - 1 if maturity_points.empty? || date > maturity_points.last
        candidates.max
      end
    end

    # Where a deposit paid at maturity pays out: the end of every term (past
    # renewals included, counted from the original date like
    # Account::Liquidity#next_release_date) and, inside a term longer than a
    # year, its yearly anniversaries counted back from the term end.
    def maturity_points
      @maturity_points ||= begin
        base = account.liquidity == "locked" ? account.available_on : nil
        base ? term_ends(base).each_cons(2).flat_map { |previous, term_end| yearly_points(term_end, previous) }.uniq.sort : []
      end
    end

    def term_ends(base)
      earliest = as_of - MAX_DAYS
      latest = as_of + MAX_DAYS
      term = account.auto_renew? ? account.renewal_term_months.to_i : 0
      return [ nil, base ] unless term.positive?

      steps_back = 0
      steps_back += 1 while (base >> (-(steps_back + 1) * term)) >= earliest
      ends = []
      step = -steps_back
      while (date = base >> (step * term)) <= latest
        ends << date
        step += 1
      end
      [ nil ] + ends
    end

    def yearly_points(term_end, previous_end)
      floor = previous_end || term_end << (12 * (MAX_DAYS / 365 + 1))
      points = []
      years = 0
      while (point = term_end << (12 * years)) > floor
        points << point
        years += 1
      end
      points
    end
end
