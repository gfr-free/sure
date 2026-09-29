require "test_helper"

class Insight::Generators::ContractGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @member = users(:family_member)
    @insurance = contracts(:liability_insurance)
    @phone = contracts(:phone_plan)
  end

  teardown do
    travel_back
  end

  test "reminds the owner of an approaching notice deadline" do
    travel_to Date.new(2026, 9, 20)

    insight = generated.find { |i| i.insight_type == "contract_notice_deadline" && i.metadata[:contract_id] == @insurance.id }

    assert insight
    assert_equal @owner.id, insight.user_id
    assert_equal "high", insight.priority
    assert_equal "2026-09-30", insight.metadata[:deadline]
    assert_equal 10, insight.facts[:days_left]
    assert_not_includes insight.facts.values.map(&:to_s).join, "LV-2024-004711", "contract numbers never reach insight facts"
  end

  test "a far-off deadline is not yet an insight" do
    travel_to Date.new(2026, 5, 1)

    assert_empty generated.select { |i| i.insight_type == "contract_notice_deadline" && i.metadata[:contract_id] == @insurance.id }
  end

  test "a price increase on a linked insurance bill points at the special termination right" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @insurance)
    bill.recurring_price_changes.create!(effective_on: 5.days.ago.to_date, previous_amount: 12, new_amount: 15.99, currency: "USD", source: "detected")

    insight = generated.find { |i| i.insight_type == "contract_price_increase" }

    assert insight
    assert_equal "contract_price_increase.special", insight.template_key
    assert_equal "high", insight.priority
  end

  test "a price increase on a bill the owner cannot see is not an insight" do
    bill = private_member_bill(contract: @insurance)
    bill.recurring_price_changes.create!(effective_on: 5.days.ago.to_date, previous_amount: 12, new_amount: 15.99, currency: "USD", source: "detected")

    assert_empty generated.select { |i| i.insight_type == "contract_price_increase" },
                 "the insight goes to the owner, so it must not carry amounts from a bill only another member can see"
  end

  test "payments after the end date on a bill the owner cannot see are not flagged" do
    bill = private_member_bill(contract: @phone)
    @phone.update!(status: "ended", ends_on: 20.days.ago.to_date)
    entry = bill.account.entries.create!(date: 5.days.ago.to_date, amount: 15.99, currency: "USD", name: "Netflix", entryable: Transaction.new)
    occurrence = bill.recurring_occurrences.create!(family: @family, original_due_on: 5.days.ago.to_date, due_on: 5.days.ago.to_date,
                                                    currency: "USD", expected_amount: 15.99, status: "scheduled")
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: entry)

    assert_empty generated.select { |i| i.insight_type == "contract_charges_after_end" }
  end

  test "a price decrease is not an insight" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)
    bill.recurring_price_changes.create!(effective_on: 5.days.ago.to_date, previous_amount: 20, new_amount: 15.99, currency: "USD", source: "detected")

    assert_empty generated.select { |i| i.insight_type == "contract_price_increase" }
  end

  test "payments after the end date are flagged" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @phone)
    @phone.update!(status: "ended", ends_on: 20.days.ago.to_date)
    entry = accounts(:depository).entries.create!(date: 5.days.ago.to_date, amount: 15.99, currency: "USD", name: "Netflix", entryable: Transaction.new)
    bill.recurring_occurrences.destroy_all
    occurrence = bill.recurring_occurrences.create!(family: @family, original_due_on: 5.days.ago.to_date, due_on: 5.days.ago.to_date,
                                                    currency: "USD", expected_amount: 15.99, status: "scheduled")
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: entry)

    insight = generated.find { |i| i.insight_type == "contract_charges_after_end" }

    assert insight
    assert_equal 1, insight.facts[:count]
    assert_equal @owner.id, insight.user_id
  end

  test "an unconfirmed cancellation is flagged after two weeks" do
    @phone.update!(status: "cancellation_sent", cancelled_on: 20.days.ago.to_date)

    assert generated.any? { |i| i.insight_type == "contract_cancellation_unconfirmed" && i.metadata[:contract_id] == @phone.id }

    @phone.update!(cancelled_on: 3.days.ago.to_date)
    assert_not generated.any? { |i| i.insight_type == "contract_cancellation_unconfirmed" }
  end

  test "nothing when the family switched bills off" do
    @family.update!(recurring_transactions_disabled: true)
    @phone.update!(status: "cancellation_sent", cancelled_on: 20.days.ago.to_date)

    assert_empty generated
  end

  private

    def generated
      Insight::Generators::ContractGenerator.new(@family.reload).generate
    end

    # An active bill on an account only @member can reach, linked to a
    # contract owned by @owner.
    def private_member_bill(contract:)
      @family.update!(default_account_sharing: "private")
      account = @family.accounts.create!(name: "Member only", balance: 0, currency: "USD",
                                         accountable: Depository.new, owner: @member)
      account.account_shares.delete_all
      @family.recurring_transactions.create!(
        account: account, name: "Private bill", amount: -15.99, currency: "USD",
        expected_day_of_month: 3, last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: 3.days.from_now.to_date, status: "active", contract: contract
      )
    end
end
