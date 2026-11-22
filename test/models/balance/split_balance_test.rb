require "test_helper"

class Balance::SplitBalanceTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 6, 15, 12)
    @account = families(:empty).accounts.create!(
      name: "Split Account", accountable: Depository.new, balance: 1000, cash_balance: 1000, currency: "USD"
    )
    @account.entries.create!(date: 3.days.ago.to_date, name: "Opening", amount: 1000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor"))
    @parent = @account.entries.create!(date: 2.days.ago.to_date, name: "Groceries", amount: 100, currency: "USD",
      entryable: Transaction.new)
    @parent.split!([ { name: "Food", amount: 60 }, { name: "Household", amount: 40, excluded: "1" } ])
  end

  teardown { travel_back }

  test "sync cache leaves the split parent out and keeps every child" do
    amounts = Balance::SyncCache.new(@account).entries.select(&:transaction?).map(&:amount)
    assert_equal [ 40, 60 ], amounts.sort
  end

  test "forward calculator counts a split once" do
    balances = Balance::ForwardCalculator.new(@account).calculate
    assert_equal 900, balances.max_by(&:date).balance
  end

  test "reverse calculator counts a split once" do
    @account.entries.valuations.destroy_all
    @account.entries.create!(date: Date.current, name: "Current", amount: 900, currency: "USD",
      entryable: Valuation.new(kind: "current_anchor"))
    balances = Balance::ReverseCalculator.new(@account).calculate
    assert_equal 1000, balances.find { |b| b.date == 3.days.ago.to_date }.balance
  end
end
