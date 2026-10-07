require "test_helper"

class Account::ForecastTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @account.update!(balance: 1000)
    @today = Account.liquidity_today_for(@family)
    # Fixture series would otherwise add their own occurrences to the account.
    @family.recurring_transactions.destroy_all
  end

  test "subtracts bills, adds income and follows transfers in and out" do
    savings = @family.accounts.create!(name: "Bills", balance: 100, currency: "USD", accountable: Depository.new(subtype: "checking"))

    occurrence(series(name: "Rent", amount: 700), due_on: @today + 3)
    occurrence(series(name: "Side job", amount: -200, bill_type: "income", manual: false), due_on: @today + 5)
    occurrence(series(name: "To bills", amount: 300, destination: savings), due_on: @today + 1)

    forecast = Account::Forecast.for_account(@account)

    assert_equal %i[transfer_out expense income], forecast.events.map(&:kind)
    assert_equal [ -300, -700, 200 ], forecast.events.map { |event| event.amount.amount.to_i }
    assert_equal 200, forecast.ending_balance.amount.to_i
    assert_equal 0, forecast.low_balance.amount.to_i
    assert_equal @today + 3, forecast.low_on
    assert_not forecast.shortfall?

    bills = Account::Forecast.for_account(savings)
    assert_equal [ :transfer_in ], bills.events.map(&:kind)
    assert_equal 400, bills.ending_balance.amount.to_i
  end

  test "a shortfall names the low day, the amount to move and the deadline" do
    occurrence(series(name: "Rent", amount: 1300), due_on: @today + 10)
    occurrence(series(name: "Phone", amount: 50), due_on: @today + 10)

    forecast = Account::Forecast.for_account(@account)

    assert forecast.shortfall?
    assert_equal(-350, forecast.low_balance.amount.to_i)
    assert_equal @today + 10, forecast.low_on
    assert_equal 350, forecast.shortfall_amount.amount.to_i
    assert_equal @today + 9, forecast.top_up_by
    assert_equal "Rent", forecast.low_cause.name
  end

  test "a bill due today that overdraws the account is a shortfall" do
    occurrence(series(name: "Rent", amount: 1100), due_on: @today)

    forecast = Account::Forecast.for_account(@account)

    assert forecast.shortfall?
    assert_equal @today, forecast.low_on
    assert_equal @today, forecast.top_up_by
  end

  test "an account already overdrawn with nothing due is not a shortfall" do
    @account.update!(balance: -50)

    assert_not Account::Forecast.for_account(@account).shortfall?
  end

  test "an explicit end date is clamped to the supported range" do
    occurrence(series(name: "Today", amount: 100), due_on: @today)

    past = Account::Forecast.for_account(@account, until_date: @today - 10)
    assert_equal @today, past.ends_on
    assert_equal [ "Today" ], past.events.map(&:name)

    assert_equal @today + Account::Forecast::MAX_HORIZON_DAYS,
                 Account::Forecast.for_account(@account, until_date: Date.new(9999, 12, 31)).ends_on
  end

  test "partial payments shrink an occurrence to what remains" do
    rent = occurrence(series(name: "Rent", amount: 700), due_on: @today + 3)
    RecurringAllocation.create!(recurring_occurrence: rent, state: :confirmed, source: :user_confirmed,
                                allocated_amount: 500, currency: "USD", paid_on: @today)

    forecast = Account::Forecast.for_account(@account)

    assert_equal [ -200 ], forecast.events.map { |event| event.amount.amount.to_i }
  end

  test "the window ends the day before the next declared payday" do
    occurrence(series(name: "Salary", amount: -2500, bill_type: "income", manual: true), due_on: @today + 12)
    occurrence(series(name: "Rent", amount: 700), due_on: @today + 11)
    occurrence(series(name: "Gym", amount: 40), due_on: @today + 13)

    forecast = Account::Forecast.for_account(@account)

    assert_equal :payday, forecast.horizon
    assert_equal @today + 12, forecast.payday
    assert_equal @today + 11, forecast.ends_on
    assert_equal [ "Rent" ], forecast.events.map(&:name)
  end

  test "without a payday the window is 30 days and overdue rows stay out" do
    occurrence(series(name: "Late", amount: 100), due_on: @today - 2)
    occurrence(series(name: "Far", amount: 100), due_on: @today + 31)
    occurrence(series(name: "Near", amount: 100), due_on: @today + 30)

    forecast = Account::Forecast.for_account(@account)

    assert_equal :default, forecast.horizon
    assert_equal @today + 30, forecast.ends_on
    assert_equal [ "Near" ], forecast.events.map(&:name)
  end

  test "an explicit end date replaces the window" do
    occurrence(series(name: "Far", amount: 100), due_on: @today + 60)

    forecast = Account::Forecast.for_account(@account, until_date: @today + 60)

    assert_equal :custom, forecast.horizon
    assert_equal [ "Far" ], forecast.events.map(&:name)
  end

  test "paused series and closed occurrences do not count" do
    occurrence(series(name: "Paused", amount: 100, status: "inactive"), due_on: @today + 2)
    occurrence(series(name: "Skipped", amount: 100), due_on: @today + 2).skip!

    assert_empty Account::Forecast.for_account(@account).events
  end

  test "family forecasts cover only available accounts with payments, in two queries" do
    occurrence(series(name: "Rent", amount: 700), due_on: @today + 3)
    cd = @family.accounts.create!(name: "Term deposit", balance: 5000, currency: "USD",
                                  accountable: Depository.new(subtype: "cd"), available_on: @today + 90)
    occurrence(series(name: "Fee", amount: 5, account: cd), due_on: @today + 3)

    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/recurring_occurrences|recurring_allocations/) }
    forecasts = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      Account::Forecast.for_family(@family)
    end

    assert_equal [ @account ], forecasts.map(&:account)
    assert_equal 2, queries.size
  end

  test "a user only sees series on accounts shared with them" do
    other = @family.accounts.create!(name: "Private", balance: 100, currency: "USD", owner: users(:family_member),
                                     accountable: Depository.new(subtype: "checking"))
    occurrence(series(name: "From private", amount: 300, account: other, destination: @account), due_on: @today + 2)

    assert_equal 1, Account::Forecast.for_account(@account).events.size
    assert_empty Account::Forecast.for_account(@account, user: users(:family_admin)).events
  end

  test "only immediate assets are forecastable" do
    assert Account::Forecast.forecastable?(@account)
    assert_not Account::Forecast.forecastable?(accounts(:credit_card))
    assert_not Account::Forecast.forecastable?(accounts(:investment))
  end

  private
    def series(name:, amount:, account: @account, destination: nil, bill_type: nil, manual: true, status: "active")
      record = @family.recurring_transactions.create!(
        name: name, account: account, destination_account: destination, amount: amount, currency: "USD",
        expected_day_of_month: 15, last_occurrence_date: @today, next_expected_date: @today + 30,
        status: status, manual: manual, bill_type: bill_type || "bill"
      )
      record.recurring_occurrences.delete_all
      record
    end

    def occurrence(series, due_on:)
      series.recurring_occurrences.create!(family: @family, original_due_on: due_on, due_on: due_on, currency: "USD")
    end
end
