require "test_helper"

class Portfolio::ExternalFlowsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Brokerage", balance: 0, currency: "USD", accountable: Investment.new)
    @date = Date.new(2024, 3, 5)
  end

  test "classifies labels" do
    assert_equal :external, classify("Transaction", nil)
    assert_equal :external, classify("Transaction", "Contribution")
    assert_equal :external, classify("Transaction", "Withdrawal")
    assert_equal :external, classify("Transaction", "Transfer")
    assert_equal :external, classify("Transaction", "Other")
    assert_equal :income, classify("Transaction", "Dividend")
    assert_equal :income, classify("Trade", "Interest")
    assert_equal :cost, classify("Transaction", "Fee")
    assert_equal :cost, classify("Trade", "Tax")
    assert_nil classify("Transaction", "Buy")
    assert_nil classify("Transaction", "Sweep Out")
    assert_nil classify("Transaction", "Exchange")
    assert_nil classify("Trade", nil)
    assert_nil classify("Trade", "Buy")
  end

  test "signs amounts from the owner's point of view" do
    transaction(-500, "Contribution")
    transaction(200, "Withdrawal")
    transaction(-30, "Dividend")
    transaction(5, "Fee")

    amounts = flows.map { |flow| [ flow.kind, flow.amount ] }

    assert_includes amounts, [ :external, 500 ]
    assert_includes amounts, [ :external, -200 ]
    assert_includes amounts, [ :income, 30 ]
    assert_includes amounts, [ :cost, 5 ]
  end

  test "counts dividend trades as income and ignores buys" do
    security = securities(:aapl)
    create_trade(security, account: @account, qty: 10, date: @date, price: 100)
    @account.entries.create!(
      name: "Dividend: AAPL", date: @date, amount: -12, currency: "USD",
      entryable: Trade.new(qty: 0, price: 0, fee: 0, currency: "USD", security: security, investment_activity_label: "Dividend")
    )

    assert_equal [ [ :income, 12 ] ], flows.map { |flow| [ flow.kind, flow.amount ] }
  end

  test "converts foreign entries with the entry's own rate, else the day's rate" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @date, rate: 1.2)
    transaction(-100, "Contribution", currency: "EUR")
    custom = transaction(-100, "Contribution", currency: "EUR")
    custom.entryable.update!(exchange_rate: 1.5)

    assert_equal [ 120, 150 ], flows.map(&:amount).sort
  end

  test "leaves out entries without an exchange rate" do
    transaction(-100, "Contribution", currency: "CHF")

    assert_empty flows
  end

  test "leaves out pending entries and entries outside the range" do
    pending = transaction(-100, "Contribution")
    pending.entryable.update!(extra: { "simplefin" => { "pending" => true } })
    transaction(-100, "Contribution", date: @date - 10)

    assert_empty flows
  end

  private
    def classify(entryable_type, label)
      Portfolio::ExternalFlows.classify(entryable_type: entryable_type, label: label)
    end

    def flows
      Portfolio::ExternalFlows.new([ @account ], start_date: @date - 1, end_date: @date + 1).flows
    end

    def transaction(amount, label, currency: "USD", date: @date)
      create_transaction(account: @account, date: date, amount: amount, currency: currency, entryable: Transaction.new(investment_activity_label: label))
    end
end
