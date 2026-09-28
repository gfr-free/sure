require "test_helper"

class Contract::CostReportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @insurance = contracts(:liability_insurance)
    @insurance.update!(details: { "insurance_line" => "liability" })
    @bill = recurring_transactions(:netflix_subscription)
    @bill.update!(contract: @insurance)
  end

  test "annual cost per kind from the viewer's contracts" do
    report = build(@admin)

    row = report.by_kind.find { |r| r.kind == "insurance" }
    assert_equal 1, row.count
    assert_in_delta @bill.monthly_equivalent_amount.amount.abs * 12, row.annual_cost.amount, 0.01
  end

  test "insurance premiums paid in the period, flagged when possibly deductible" do
    entry = accounts(:depository).entries.create!(date: Date.current.beginning_of_year + 10, amount: 15.99, currency: "USD", name: "Premium", entryable: Transaction.new)
    @bill.recurring_occurrences.destroy_all
    occurrence = @bill.recurring_occurrences.create!(family: @family, original_due_on: entry.date, due_on: entry.date,
                                                     currency: "USD", expected_amount: 15.99, status: "scheduled")
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: entry)

    report = build(@admin)

    row = report.insurance.first
    assert_equal @insurance, row.contract
    assert row.possibly_deductible
    assert_in_delta 15.99, row.paid.amount, 0.01
    assert_in_delta 15.99, report.possibly_deductible_total.amount, 0.01
  end

  test "a member only sees the contracts shared with them" do
    report = build(@member)

    assert_not report.contracts.include?(@insurance)
    assert report.contracts.include?(contracts(:phone_plan))
  end

  private

    def build(user)
      Contract::CostReport.new(family: @family, user: user, start_date: Date.current.beginning_of_year, end_date: Date.current.end_of_year)
    end
end
