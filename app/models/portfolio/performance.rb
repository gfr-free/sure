# How investment accounts performed over a date range, in one currency.
#
# Two returns answer two questions:
#
#   money_weighted_return  What did my money earn? (XIRR) The rate at which
#                          the deposits and withdrawals, as they happened, grow
#                          into the value at the end. It depends on when money
#                          went in, which is what a saver lives with.
#   time_weighted_return   How did my investments do? (TWR) Daily returns,
#                          chained, with deposits and withdrawals taken out, so
#                          it compares fairly with an index.
#
# Both are shown as the actual change over ranges shorter than a year and as a
# rate per year from a year on, because a week's +2 % read as "+180 % a year"
# says nothing useful.
#
# Values are the stored daily end balances of each account; flows come from
# Portfolio::ExternalFlows. Both are converted into the target currency at the
# day's rate, or, with fixed_rates, at the closing rate of the range for every
# day, which takes currency movements between the accounts' currencies and the
# target currency out of the result. An account whose currency has no rate at
# all is left out and reported through missing_rates.
class Portfolio::Performance
  DAYS_PER_YEAR = 365

  Result = Data.define(
    :start_date, :end_date, :currency,
    :start_value, :end_value, :deposits, :withdrawals, :income, :costs,
    :money_weighted_return, :time_weighted_return, :annualized, :ambiguous, :missing_rates
  ) do
    def net_flows
      deposits - withdrawals
    end

    def gain
      end_value - start_value - net_flows
    end

    def start_value_money = Money.new(start_value, currency)
    def end_value_money = Money.new(end_value, currency)
    def deposits_money = Money.new(deposits, currency)
    def withdrawals_money = Money.new(withdrawals, currency)
    def net_flows_money = Money.new(net_flows, currency)
    def income_money = Money.new(income, currency)
    def costs_money = Money.new(costs, currency)
    def gain_money = Money.new(gain, currency)
  end

  attr_reader :accounts, :start_date, :end_date, :currency

  def initialize(accounts:, start_date:, end_date:, currency:, fixed_rates: false)
    @accounts = accounts.to_a
    @start_date = start_date
    @end_date = end_date
    @currency = currency
    @fixed_rates = fixed_rates
  end

  def result
    @result ||= cached(:result) { build_result }
  end

  # { [year, month] => BigDecimal } time-weighted return of each month in the
  # range, and { year => BigDecimal } for each year. Months without a day that
  # had money invested at its start are absent.
  def monthly_returns
    period_returns.fetch(:monthly)
  end

  def yearly_returns
    period_returns.fetch(:yearly)
  end

  private
    def build_result
      daily = daily_series
      twr = chained_return(daily)
      xirr = money_weighted(daily)

      Result.new(
        start_date: start_date,
        end_date: end_date,
        currency: currency,
        start_value: daily[:values].fetch(opening_date, 0.to_d),
        end_value: daily[:values].fetch(end_date, 0.to_d),
        deposits: daily[:deposits],
        withdrawals: daily[:withdrawals],
        income: daily[:income],
        costs: daily[:costs],
        money_weighted_return: xirr && xirr[:rate],
        time_weighted_return: twr && displayed_time_weighted(twr),
        annualized: annualized?,
        ambiguous: xirr ? xirr[:ambiguous] : false,
        missing_rates: daily[:missing_rates]
      )
    end

    def period_returns
      @period_returns ||= cached(:period_returns) do
        daily = daily_series
        monthly = Hash.new { |hash, key| hash[key] = 1.to_d }
        yearly = Hash.new { |hash, key| hash[key] = 1.to_d }

        each_daily_factor(daily) do |date, factor|
          monthly[[ date.year, date.month ]] *= factor
          yearly[date.year] *= factor
        end

        {
          monthly: monthly.transform_values { |factor| factor - 1 },
          yearly: yearly.transform_values { |factor| factor - 1 }
        }
      end
    end

    # The value at the end of the day before the range is the starting value.
    def opening_date
      start_date - 1
    end

    def days
      (end_date - start_date).to_i + 1
    end

    def annualized?
      days >= DAYS_PER_YEAR
    end

    # Values and flows per day in the target currency, summed over accounts.
    def daily_series
      @daily_series ||= begin
        values = Hash.new(0.to_d)
        net_flows = Hash.new(0.to_d)
        totals = { deposits: 0.to_d, withdrawals: 0.to_d, income: 0.to_d, costs: 0.to_d }
        included = accounts.select { |account| rates.available?(account.currency) }
        missing_rates = included.size < accounts.size
        balances = balances_by_account(included)

        currencies = included.to_h { |account| [ account.id, account.currency ] }
        external_by_account_day = Hash.new(0.to_d)

        add_external = lambda do |date, amount|
          net_flows[date] += amount
          amount.positive? ? totals[:deposits] += amount : totals[:withdrawals] -= amount
        end

        Portfolio::ExternalFlows.new(included, start_date: start_date, end_date: end_date).flows.each do |flow|
          amount = flow.amount * rate(currencies.fetch(flow.account_id), flow.date)

          case flow.kind
          when :external
            add_external.call(flow.date, amount)
            external_by_account_day[[ flow.account_id, flow.date ]] += flow.amount
          when :income
            totals[:income] += amount
          when :cost
            totals[:costs] += amount
          end
        end

        included.each do |account|
          opening_value = balances[:opening][account.id]
          account_balances = balances[:daily][account.id] || {}
          last_value = opening_value || 0.to_d

          (opening_date..end_date).each do |date|
            last_value = account_balances[date] if account_balances.key?(date)
            values[date] += last_value * rate(account.currency, date)
          end

          # An account whose history starts inside the range (a new or newly
          # linked account) jumps from nothing to its opening balance. That
          # balance was brought in, not earned: whatever the entries of its
          # first day do not explain counts as money paid in.
          first_date = account_balances.keys.min
          next if opening_value || first_date.nil? || first_date <= opening_date

          implied = account_balances[first_date] - external_by_account_day[[ account.id, first_date ]]
          add_external.call(first_date, implied * rate(account.currency, first_date)) unless implied.zero?
        end

        totals.merge(values: values, net_flows: net_flows, missing_rates: missing_rates)
      end
    end

    # One query for the stored balances inside the range and one for each
    # account's last balance before it, which carries into days without a row.
    # Only rows in the account's own currency are read: a currency change
    # leaves rows in the old currency behind.
    def balances_by_account(included)
      return { daily: {}, opening: {} } if included.empty?

      ids = included.map(&:id)
      scope = Balance.joins(:account).where(account_id: ids).where("balances.currency = accounts.currency")

      daily = scope.where(date: opening_date..end_date)
        .pluck(:account_id, :date, :end_balance)
        .each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |(account_id, date, balance), map|
          map[account_id][date] = balance.to_d
        end

      opening = scope.where(balances: { date: ...opening_date })
        .select("DISTINCT ON (balances.account_id) balances.account_id, balances.end_balance")
        .order("balances.account_id, balances.date DESC")
        .to_h { |balance| [ balance.account_id, balance.end_balance.to_d ] }

      { daily: daily, opening: opening }
    end

    def rates
      @rates ||= Portfolio::DailyRates.new(to: currency, start_date: opening_date, end_date: end_date)
    end

    def rate(from, date)
      @fixed_rates ? rates.closing_rate(from) : rates.rate(from, date)
    end

    # Chains (V_t - F_t) / V_(t-1) over the range. Flows count at the end of
    # their day. Days that start with nothing invested carry no return.
    def chained_return(daily)
      factor = nil
      each_daily_factor(daily) { |_date, day_factor| factor = (factor || 1.to_d) * day_factor }
      factor && factor - 1
    end

    def each_daily_factor(daily)
      values = daily[:values]
      (start_date..end_date).each do |date|
        previous = values[date - 1]
        next unless previous.positive?

        yield date, (values[date] - daily[:net_flows][date]) / previous
      end
    end

    # From the owner's point of view: the starting value and every deposit
    # are paid in (negative), withdrawals and the end value are received.
    #
    # Over a year or more the rate is solved per year. Over a shorter range it
    # is solved per the time money was actually invested (from the first
    # payment to the end), which gives the change over that time directly; a
    # yearly rate for a few days would overflow the solver on any large move.
    def money_weighted(daily)
      flows = [ [ opening_date, -daily[:values][opening_date] ] ]
      daily[:net_flows].each { |date, amount| flows << [ date, -amount ] }
      flows << [ end_date, daily[:values][end_date] ]

      first_date = flows.reject { |_, amount| amount.zero? }.map(&:first).min
      return nil if first_date.nil? || first_date >= end_date

      unit = annualized? ? DAYS_PER_YEAR : (end_date - first_date).to_i
      xirr = Portfolio::Xirr.new(flows, days_per_unit: unit)
      { rate: xirr.rate, ambiguous: xirr.ambiguous? }
    rescue Portfolio::Xirr::NoSignChangeError, Portfolio::Xirr::NoDurationError, Portfolio::Xirr::ConvergenceError
      nil
    end

    def displayed_time_weighted(cumulative)
      return cumulative unless annualized?

      rescale(cumulative, DAYS_PER_YEAR / days.to_f)
    end

    # (1 + r) ** exponent - 1, in Float like Portfolio::Xirr (BigDecimal has
    # no fractional powers), returned as BigDecimal.
    def rescale(rate, exponent)
      base = 1 + rate.to_f
      return BigDecimal("-1") if base <= 0

      BigDecimal(((base**exponent) - 1).to_s)
    end

    def cached(name, &block)
      family = accounts.first&.family
      return yield if family.nil?

      key = [
        "portfolio_performance", name, 1,
        family.build_cache_key("portfolio_performance", invalidate_on_data_updates: true),
        family.entries_cache_version,
        Digest::MD5.hexdigest(accounts.map(&:id).sort.join(",")),
        start_date, end_date, currency, @fixed_rates
      ]

      Rails.cache.fetch(key, expires_in: 1.day, &block)
    end
end
