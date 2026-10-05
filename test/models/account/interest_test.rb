require "test_helper"

class Account::InterestTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
  end

  test "the first rate applies from the start of the account" do
    travel_to Time.zone.local(2026, 1, 15, 12) do
      @account.update!(interest_rate_input: "3.5", interest_payout_frequency: "quarterly")

      entry = @account.interest_rates.sole
      assert_equal "credit", entry.applies_to
      assert_equal BigDecimal("3.5"), entry.rate
      assert_equal [ @account.start_date, Date.current ].min, entry.effective_from
      assert_equal "quarterly", @account.reload.interest_payout_frequency
      assert @account.interest_terms?
    end
  end

  test "a changed rate applies from today and keeps the history" do
    @account.interest_rates.create!(effective_from: Date.new(2025, 1, 1), rate: 3)

    travel_to Time.zone.local(2026, 1, 15, 12) do
      @account.update!(interest_rate_input: "2,5")

      assert_equal [ BigDecimal("3"), BigDecimal("2.5") ], @account.interest_rates.chronological.map(&:rate)
      assert_equal Date.current, @account.interest_rates.chronological.last.effective_from
      assert_equal BigDecimal("2.5"), @account.reload.interest_rate_on(Date.current)
      assert_equal BigDecimal("3"), @account.interest_rate_on(Date.current - 1)
    end
  end

  test "submitting the unchanged rate writes nothing and clearing it removes the rate" do
    @account.interest_rates.create!(effective_from: Date.new(2025, 1, 1), rate: 3)
    @account.interest_rates.create!(effective_from: 1.year.from_now.to_date, rate: 1)

    assert_no_difference -> { @account.interest_rates.count } do
      @account.update!(interest_rate_input: "3.0")
    end

    @account.update!(interest_rate_input: "")
    assert_empty @account.interest_rates.reload
    assert_not @account.reload.interest_terms?
  end

  test "an empty rate field keeps a planned rate when no rate applies yet" do
    @account.interest_rates.create!(effective_from: 1.month.from_now.to_date, rate: 2)

    @account.update!(name: "Renamed", interest_rate_input: "")

    assert_equal 1, @account.interest_rates.count
  end

  test "a planned change becomes a future entry" do
    @account.update!(interest_rate_input: "3.5", planned_interest_rate: "1.5", planned_interest_rate_on: 2.months.from_now.to_date.iso8601)

    upcoming = @account.reload.upcoming_interest_rates
    assert_equal 1, upcoming.size
    assert_equal BigDecimal("1.5"), upcoming.first.rate
  end

  test "a planned change needs a rate and a date after today" do
    @account.assign_attributes(planned_interest_rate: "1.5", planned_interest_rate_on: Date.current.iso8601)
    assert_not @account.valid?
    assert @account.errors[:planned_interest_rate_on].any?

    @account.assign_attributes(planned_interest_rate: "", planned_interest_rate_on: 1.month.from_now.to_date.iso8601)
    assert_not @account.valid?
    assert @account.errors[:planned_interest_rate].any?
  end

  test "rejects rates that are not numbers or out of range" do
    @account.interest_rate_input = "abc"
    assert_not @account.valid?

    @account.interest_rate_input = "1000"
    assert_not @account.valid?
  end

  test "the overdraft rate is a debit entry on bank accounts" do
    @account.update!(overdraft_rate_input: "11.9")

    assert_equal "debit", @account.interest_rates.sole.applies_to
    assert_equal BigDecimal("11.9"), @account.interest_rate_on(Date.current, applies_to: "debit")
    assert_nil @account.interest_rate_on(Date.current)
  end

  test "only bank and other-asset accounts take interest terms" do
    assert accounts(:depository).interest_capable?
    assert accounts(:other_asset).interest_capable?
    assert_not accounts(:investment).interest_capable?
    assert_not accounts(:credit_card).interest_capable?

    investment = accounts(:investment)
    investment.update!(interest_payout_frequency: "monthly", interest_rate_input: "3")
    assert_nil investment.reload.interest_payout_frequency
    assert_empty investment.interest_rates
  end

  test "credit cards read their APR and loans their own rate" do
    card = accounts(:credit_card)
    card.accountable.update!(apr: 18.9)
    assert_equal BigDecimal("18.9"), card.interest_rate_on(Date.current, applies_to: "debit")
    assert_nil card.interest_rate_on(Date.current)

    loan = accounts(:loan)
    assert_equal loan.accountable.interest_rate, loan.interest_rate_on(Date.current, applies_to: "debit")
  end

  test "the payout rhythm follows the subtype until the user picks one" do
    cd = Account.new(accountable: Depository.new(subtype: "cd"))
    assert_equal "at_maturity", cd.effective_interest_payout_frequency
    assert_equal "monthly", Account.new(accountable: Depository.new(subtype: "savings")).effective_interest_payout_frequency
    assert_equal "annual", Account.new(accountable: Depository.new(subtype: "building_savings")).effective_interest_payout_frequency

    cd.interest_payout_frequency = "annual"
    assert_equal "annual", cd.effective_interest_payout_frequency
  end
end
