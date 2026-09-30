require "test_helper"

class Portfolio::PerformanceTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @family = families(:empty)
    @account = create_investment_account("Brokerage", currency: "USD")
    @start = Date.new(2024, 3, 1)
  end

  test "without flows both returns equal the change in value" do
    balances(@account, @start - 1 => 1000, @start + 9 => 1100)

    result = performance(@start, @start + 9).result

    assert_in_delta 0.10, result.time_weighted_return, 0.0001
    assert_in_delta 0.10, result.money_weighted_return, 0.0001
    assert_equal 100, result.gain
    assert_not result.annualized
  end

  test "a deposit does not distort the time-weighted return but does change the money-weighted one" do
    balances(@account, @start - 1 => 1000, @start => 1100, @start + 1 => 2100, @start + 30 => 2310)
    flow(@account, @start + 1, -1000, "Contribution")

    result = performance(@start, @start + 30).result

    # +10 %, then the deposit, then +10 % on the larger amount. The deposit
    # missed the first 10 %, so the money as a whole earned less than the
    # investments did.
    assert_in_delta 0.21, result.time_weighted_return, 0.0001
    assert result.money_weighted_return.between?(0.10, 0.21)
    assert_equal 1000, result.deposits
    assert_equal 0, result.withdrawals
    assert_equal 310, result.gain
  end

  test "money-weighted return matches a known series" do
    # 1000 in, 1100 out a year later is 10 % a year.
    balances(@account, @start - 1 => 1000, @start + 364 => 1100)

    result = performance(@start, @start + 364).result

    assert result.annualized
    assert_in_delta 0.10, result.money_weighted_return, 0.0001
    assert_in_delta 0.10, result.time_weighted_return, 0.0001
  end

  test "ranges of a year or more are shown per year" do
    balances(@account, @start - 1 => 1000, @start + 729 => 1210)

    result = performance(@start, @start + 729).result

    assert result.annualized
    assert_in_delta 0.10, result.time_weighted_return, 0.001
    assert_in_delta 0.10, result.money_weighted_return, 0.001
  end

  test "ranges under a year show the actual change, not a yearly rate" do
    balances(@account, @start - 1 => 1000, @start + 6 => 1020)

    result = performance(@start, @start + 6).result

    assert_not result.annualized
    assert_in_delta 0.02, result.money_weighted_return, 0.0001
    assert_in_delta 0.02, result.time_weighted_return, 0.0001
  end

  test "income and costs count toward the return, trades and internal moves are ignored" do
    balances(@account, @start - 1 => 1000, @start + 9 => 1035)
    flow(@account, @start + 1, -50, "Dividend")
    flow(@account, @start + 2, 10, "Fee")
    flow(@account, @start + 3, 5, "Tax")
    flow(@account, @start + 4, 400, "Buy")
    flow(@account, @start + 5, -400, "Sweep In")

    result = performance(@start, @start + 9).result

    assert_equal 50, result.income
    assert_equal 15, result.costs
    assert_equal 0, result.net_flows
    assert_in_delta 0.035, result.time_weighted_return, 0.0001
  end

  test "entries without a label count as deposits and withdrawals" do
    balances(@account, @start - 1 => 1000, @start + 1 => 1500, @start + 2 => 1300)
    flow(@account, @start + 1, -500, nil)
    flow(@account, @start + 2, 200, nil)

    result = performance(@start, @start + 2).result

    assert_equal 500, result.deposits
    assert_equal 200, result.withdrawals
    assert_in_delta 0, result.time_weighted_return, 0.0001
  end

  test "days before the first deposit carry no return" do
    balances(@account, @start + 4 => 1000, @start + 9 => 1100)
    flow(@account, @start + 4, -1000, "Contribution")

    result = performance(@start, @start + 9).result

    assert_equal 0, result.start_value
    assert_in_delta 0.10, result.time_weighted_return, 0.0001
    assert_in_delta 0.10, result.money_weighted_return, 0.0001
  end

  test "an account opened inside the range brings its opening balance in rather than earning it" do
    balances(@account, @start - 1 => 1000, @start + 4 => 1100)
    added = create_investment_account("Linked later", currency: "USD")
    balances(added, @start + 5 => 5000, @start + 9 => 5000)

    result = performance(@start, @start + 9, accounts: [ @account, added ]).result

    assert_equal 5000, result.deposits
    assert_equal 100, result.gain
    assert_in_delta 0.10, result.time_weighted_return, 0.0001
  end

  test "a large move over a few days still has a money-weighted return" do
    balances(@account, @start - 1 => 1000, @start + 1 => 1100)

    result = performance(@start, @start + 1).result

    assert_in_delta 0.10, result.money_weighted_return, 0.0001
  end

  test "returns are nil without any value" do
    result = performance(@start, @start + 9).result

    assert_nil result.time_weighted_return
    assert_nil result.money_weighted_return
    assert_equal 0, result.gain
  end

  test "days without a stored balance carry the last value" do
    balances(@account, @start - 10 => 1000, @start + 9 => 1100)

    result = performance(@start, @start + 9).result

    assert_equal 1000, result.start_value
    assert_in_delta 0.10, result.time_weighted_return, 0.0001
  end

  test "converts foreign accounts at the day's rate or at one fixed rate" do
    eur = create_investment_account("Depot EUR", currency: "EUR")
    balances(eur, @start - 1 => 1000, @start + 9 => 1000)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @start - 1, rate: 1.0)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @start + 9, rate: 1.1)

    with_currency_effect = performance(@start, @start + 9, accounts: [ eur ]).result
    without_currency_effect = performance(@start, @start + 9, accounts: [ eur ], fixed_rates: true).result

    assert_in_delta 0.10, with_currency_effect.time_weighted_return, 0.0001
    assert_in_delta 0, without_currency_effect.time_weighted_return, 0.0001
    assert_equal 1100, without_currency_effect.end_value
  end

  test "days before the first rate in range use the last earlier rate" do
    eur = create_investment_account("Depot EUR", currency: "EUR")
    balances(eur, @start - 1 => 1000, @start + 30 => 1000)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @start - 60, rate: 1.0)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @start + 30, rate: 1.1)

    result = performance(@start, @start + 30, accounts: [ eur ]).result

    assert_equal 1000, result.start_value
    assert_in_delta 0.10, result.time_weighted_return, 0.0001
  end

  test "leaves out accounts whose currency has no rate and says so" do
    chf = create_investment_account("Depot CHF", currency: "CHF")
    balances(chf, @start - 1 => 5000, @start + 9 => 1)
    balances(@account, @start - 1 => 1000, @start + 9 => 1100)

    result = performance(@start, @start + 9, accounts: [ @account, chf ]).result

    assert result.missing_rates
    assert_in_delta 0.10, result.time_weighted_return, 0.0001
  end

  test "monthly returns chain into the yearly and total return" do
    balances(@account, Date.new(2023, 12, 31) => 1000, Date.new(2024, 1, 31) => 1100, Date.new(2024, 2, 29) => 1210)

    performance = performance(Date.new(2024, 1, 1), Date.new(2024, 2, 29))

    assert_in_delta 0.10, performance.monthly_returns.fetch([ 2024, 1 ]), 0.0001
    assert_in_delta 0.10, performance.monthly_returns.fetch([ 2024, 2 ]), 0.0001
    assert_in_delta 0.21, performance.yearly_returns.fetch(2024), 0.0001
    assert_in_delta 0.21, performance.result.time_weighted_return, 0.0001
  end

  private
    def create_investment_account(name, currency:)
      @family.accounts.create!(name: name, balance: 0, currency: currency, accountable: Investment.new)
    end

    def performance(start_date, end_date, accounts: [ @account ], fixed_rates: false)
      Portfolio::Performance.new(accounts: accounts, start_date: start_date, end_date: end_date, currency: "USD", fixed_rates: fixed_rates)
    end

    def balances(account, values)
      values.each { |date, balance| create_balance(account: account, date: date, balance: balance) }
    end

    # amount as stored on the entry: positive leaves the account.
    def flow(account, date, amount, label)
      account.entries.create!(
        name: label || "Transfer",
        date: date,
        amount: amount,
        currency: account.currency,
        entryable: Transaction.new(investment_activity_label: label)
      )
    end
end
