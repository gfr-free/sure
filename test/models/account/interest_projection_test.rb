require "test_helper"

class Account::InterestProjectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "accrues since the last payout and estimates the next one (EUR, 30/360)" do
    account = bank_account(currency: "EUR", balance: 12_000)
    account.interest_rates.create!(effective_from: Date.new(2025, 12, 1), rate: 3)
    add_balance(account, Date.new(2025, 12, 1), 12_000)

    travel_to Time.zone.local(2026, 1, 20, 12) do
      projection = account.reload.interest_projection

      assert_equal Money.new(20, "EUR"), projection.accrued
      assert_equal Date.new(2026, 1, 31), projection.next_payout.date
      assert_equal Money.new(30, "EUR"), projection.next_payout.amount
    end
  end

  test "a rate change in the period applies from its date" do
    account = bank_account(currency: "EUR", balance: 12_000)
    account.interest_rates.create!(effective_from: Date.new(2025, 12, 1), rate: 3)
    account.interest_rates.create!(effective_from: Date.new(2026, 1, 11), rate: 1.5)
    add_balance(account, Date.new(2025, 12, 1), 12_000)

    travel_to Time.zone.local(2026, 1, 20, 12) do
      assert_equal Money.new(15, "EUR"), account.reload.interest_projection.accrued
    end
  end

  test "an overdraft is charged at the debit rate" do
    account = bank_account(currency: "USD", balance: -1000)
    account.interest_rates.create!(effective_from: Date.new(2025, 12, 1), rate: 3, applies_to: "credit")
    account.interest_rates.create!(effective_from: Date.new(2025, 12, 1), rate: 10, applies_to: "debit")
    add_balance(account, Date.new(2026, 1, 1), -1000)

    travel_to Time.zone.local(2026, 1, 10, 12) do
      assert_equal Money.new(-2.74, "USD"), account.reload.interest_projection.accrued
    end
  end

  test "a one-year term deposit paid at maturity earns simple interest" do
    account = bank_account(currency: "USD", balance: 10_000, subtype: "cd", available_on: Date.new(2026, 6, 30))
    account.interest_rates.create!(effective_from: Date.new(2025, 7, 1), rate: 4)
    add_balance(account, Date.new(2025, 7, 1), 10_000)

    travel_to Time.zone.local(2026, 1, 15, 12) do
      projection = account.reload.interest_projection

      assert_equal "at_maturity", projection.frequency
      assert_equal Money.new(218.08, "USD"), projection.accrued
      assert_equal Date.new(2026, 6, 30), projection.next_payout.date
      assert_equal Money.new(10_400, "USD"), projection.value_at_maturity
    end
  end

  test "a longer term capitalises once a year" do
    account = bank_account(currency: "USD", balance: 10_000, subtype: "cd", available_on: Date.new(2027, 6, 30))
    account.interest_rates.create!(effective_from: Date.new(2025, 7, 1), rate: 4)
    add_balance(account, Date.new(2025, 7, 1), 10_000)

    travel_to Time.zone.local(2025, 7, 1, 12) do
      # 400 in the first year, then 4 % on 10,400 in the second.
      assert_equal Money.new(10_816, "USD"), account.reload.interest_projection.value_at_maturity
    end
  end

  test "an auto-renewing deposit pays at the end of every term" do
    account = bank_account(currency: "USD", balance: 10_000, subtype: "cd", available_on: Date.new(2025, 7, 31))
    account.update!(auto_renew: true, renewal_term_months: 3)
    account.interest_rates.create!(effective_from: Date.new(2025, 1, 1), rate: 3.65)
    add_balance(account, Date.new(2025, 1, 1), 10_000)

    travel_to Time.zone.local(2026, 1, 15, 12) do
      projection = account.reload.interest_projection

      # The last renewal was on 2025-10-31; 3.65 % on 10,000 is 1.00 a day.
      assert_equal Money.new(76, "USD"), projection.accrued
      assert_equal Date.new(2026, 1, 31), projection.next_payout.date
      assert_equal Money.new(92, "USD"), projection.next_payout.amount
    end
  end

  test "after a deposit matured without renewing, interest counts yearly again" do
    account = bank_account(currency: "USD", balance: 10_000, subtype: "cd", available_on: Date.new(2025, 6, 30))
    account.interest_rates.create!(effective_from: Date.new(2024, 7, 1), rate: 3.65)
    add_balance(account, Date.new(2024, 7, 1), 10_000)

    travel_to Time.zone.local(2026, 1, 15, 12) do
      projection = account.reload.interest_projection

      assert_equal Money.new(15, "USD"), projection.accrued
      assert_nil projection.value_at_maturity
    end
  end

  test "without a rate there is nothing to project" do
    account = bank_account(currency: "USD", balance: 1000)

    projection = account.interest_projection
    assert_not account.interest_terms?
    assert_equal Money.new(0, "USD"), projection.accrued
    assert_nil projection.value_at_maturity
  end

  private
    def bank_account(currency:, balance:, subtype: "savings", available_on: nil)
      @family.accounts.create!(name: "Interest #{SecureRandom.hex(3)}", balance: balance, currency: currency,
                               available_on: available_on, accountable: Depository.new(subtype: subtype))
    end

    def add_balance(account, date, amount)
      account.balances.create!(date: date, balance: amount, start_cash_balance: amount, currency: account.currency)
    end
end
