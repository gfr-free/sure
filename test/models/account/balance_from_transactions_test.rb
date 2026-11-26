require "test_helper"

class Account::BalanceFromTransactionsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:connected)
    @account.entries.destroy_all
    @account.balances.delete_all
  end

  test "switching on records the day, and the first calculation the start" do
    @account.balances.create!(date: 3.days.ago.to_date, balance: 900, cash_balance: 900, start_cash_balance: 900, currency: "USD")
    @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, cash_balance: 1000, start_cash_balance: 1000, currency: "USD")

    @account.update!(balance_from_transactions: true)

    assert @account.balance_from_transactions?
    assert_equal Date.current, @account.balance_from_transactions_since
    assert_nil @account.balance_from_transactions_start_cash
    assert_equal :forward, @account.balance_strategy

    materialize

    assert_equal 1000, @account.balance_from_transactions_start_cash
    assert_equal 0, @account.balance_from_transactions_start_non_cash
    assert_equal 0, @account.balance_from_transactions_ledger_total
  end

  test "without a balance before the switch, the start is the switch day's opening balance" do
    @account.balances.create!(date: Date.current, balance: 950, cash_balance: 950, start_cash_balance: 2500, cash_outflows: 1550, currency: "USD")
    @account.update!(balance_from_transactions: true)

    @account.record_balance_from_transactions_start!

    assert_equal 2500, @account.balance_from_transactions_start_cash
  end

  test "switching on again keeps the first start" do
    @account.update!(balance_from_transactions: true)
    @account.update_columns(balance_from_transactions_since: 5.days.ago.to_date, balance_from_transactions_start_cash: 42)

    @account.update!(balance_from_transactions: "1")
    @account.record_balance_from_transactions_start!

    assert_equal 5.days.ago.to_date, @account.balance_from_transactions_since
    assert_equal 42, @account.balance_from_transactions_start_cash
  end

  test "switching off clears the start" do
    @account.update!(balance_from_transactions: true)
    @account.record_balance_from_transactions_start!
    @account.update!(balance_from_transactions: "0")

    refute @account.balance_from_transactions?
    assert_nil @account.balance_from_transactions_start_cash
    assert_nil @account.balance_from_transactions_ledger_total
    assert_equal :reverse, @account.balance_strategy
  end

  test "manual and investment accounts cannot be switched on" do
    manual = accounts(:depository)
    manual.update!(balance_from_transactions: true)
    refute manual.balance_from_transactions?
    refute manual.supports_balance_from_transactions?

    investment = accounts(:investment)
    investment.stubs(:linked?).returns(true)
    refute investment.supports_balance_from_transactions?
    investment.balance_from_transactions = true
    refute investment.balance_from_transactions?
  end

  test "a provider balance is not anchored while the account keeps its own" do
    @account.update!(balance_from_transactions: true)

    result = @account.set_current_balance(5000)

    assert result.success?
    refute result.changes_made?
    assert_empty @account.valuations.current_anchor
  end

  test "a provider writing the balance directly does not replace the calculated one" do
    @account.update!(balance_from_transactions: true)
    @account.update_columns(balance: 800, cash_balance: 800)

    @account.update!(balance: 5000, cash_balance: 5000, name: "Renamed by provider")

    @account.reload
    assert_equal 800, @account.balance
    assert_equal 800, @account.cash_balance
    assert_equal "Renamed by provider", @account.name
  end

  test "balances before the switch stay, later ones add transactions to the start" do
    switch_day = Date.current

    travel_to 5.days.ago do
      @account.set_current_balance(1000)
      create_transaction(account: @account, date: 2.days.ago.to_date, amount: 100)
      Balance::Materializer.new(@account, strategy: :reverse).materialize_balances
    end

    before_switch = @account.balances.order(:date).pluck(:date, :balance)
    assert_equal 1000, @account.balances.find_by(date: 5.days.ago.to_date).balance

    @account.update!(balance_from_transactions: true)

    # The provider still reports a balance; it is left out.
    @account.set_current_balance(5000)
    create_transaction(account: @account, date: switch_day, amount: 200)

    materialize

    assert_equal 1000, @account.balance_from_transactions_start_cash
    assert_equal 800, @account.balance
    assert_equal 800, @account.balances.find_by(date: switch_day).balance
    assert_equal before_switch, @account.balances.where(date: ...switch_day).order(:date).pluck(:date, :balance)
  end

  test "a transaction dated before the switch but imported after it counts from the switch on" do
    @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, cash_balance: 1000, start_cash_balance: 1000, currency: "USD")
    create_transaction(account: @account, date: 3.days.ago.to_date, amount: 40)
    @account.update!(balance_from_transactions: true)
    materialize
    assert_equal 1000, @account.balance

    # The bank books yesterday's card payment a day late.
    create_transaction(account: @account, date: 1.day.ago.to_date, amount: 80)
    materialize

    assert_equal 920, @account.balance
    assert_equal 1000, @account.balances.find_by(date: 1.day.ago.to_date).balance
  end

  test "a day without transactions after the switch shows the start" do
    @account.balances.create!(date: 1.day.ago.to_date, balance: 700, cash_balance: 700, start_cash_balance: 700, currency: "USD")
    create_transaction(account: @account, date: 10.days.ago.to_date, amount: 50)
    @account.update!(balance_from_transactions: true)

    materialize

    assert_equal 700, @account.balance
    assert_equal 700, @account.balances.find_by(date: Date.current).balance
  end

  test "balances before the switch are kept when the oldest transaction goes away" do
    oldest = create_transaction(account: @account, date: 10.days.ago.to_date, amount: 50)
    create_transaction(account: @account, date: 4.days.ago.to_date, amount: 20)
    @account.balances.create!(date: 10.days.ago.to_date, balance: 750, cash_balance: 750, start_cash_balance: 800, cash_outflows: 50, currency: "USD")
    @account.balances.create!(date: 1.day.ago.to_date, balance: 700, cash_balance: 700, start_cash_balance: 700, currency: "USD")
    @account.update!(balance_from_transactions: true)
    materialize

    oldest.destroy!
    materialize

    assert @account.balances.exists?(date: 10.days.ago.to_date)
  end

  test "an anchor already dated on the switch day does not override the transactions" do
    @account.set_current_balance(3000)
    @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, cash_balance: 1000, start_cash_balance: 1000, currency: "USD")
    @account.update!(balance_from_transactions: true)
    create_transaction(account: @account, date: Date.current, amount: -250)

    materialize

    assert_equal 1250, @account.balance
  end

  test "switching off goes back to the provider balance" do
    @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, cash_balance: 1000, start_cash_balance: 1000, currency: "USD")
    @account.update!(balance_from_transactions: true)
    materialize
    @account.update!(balance_from_transactions: false)

    @account.set_current_balance(5000)
    materialize

    assert_equal 5000, @account.balance
  end

  test "an account unlinked with the switch on is rebuilt like any manual account" do
    @account.update!(balance_from_transactions: true)
    @account.stubs(:linked?).returns(false)

    refute @account.calculates_balance_from_transactions?
    assert_equal :forward, @account.balance_strategy
  end

  private
    def materialize
      Balance::Materializer.new(@account, strategy: @account.balance_strategy).materialize_balances
      @account.reload
    end
end
