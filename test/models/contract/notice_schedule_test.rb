require "test_helper"

class Contract::NoticeScheduleTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "insurance renewing on its main due date: three months to the end of the year" do
    contract = build(started_on: Date.new(2024, 1, 1), minimum_term_months: 12, renewal_period_months: 12,
                     renewal_anchor_on: Date.new(2025, 1, 1), notice: [ 3, "months" ], anchor: "end_of_term")

    result = schedule(contract, Date.new(2026, 6, 15))

    assert_equal Date.new(2026, 12, 31), result.term_ends_on
    assert_equal Date.new(2026, 9, 30), result.notice_deadline
  end

  test "a missed deadline moves to the next term" do
    contract = build(started_on: Date.new(2024, 1, 1), minimum_term_months: 12, renewal_period_months: 12,
                     notice: [ 3, "months" ], anchor: "end_of_term")

    result = schedule(contract, Date.new(2026, 10, 1))

    assert_equal Date.new(2027, 12, 31), result.term_ends_on
    assert_equal Date.new(2027, 9, 30), result.notice_deadline
  end

  test "the deadline day itself still counts" do
    contract = build(started_on: Date.new(2024, 1, 1), minimum_term_months: 12, renewal_period_months: 12,
                     notice: [ 3, "months" ], anchor: "end_of_term")

    assert_equal Date.new(2026, 9, 30), schedule(contract, Date.new(2026, 9, 30)).notice_deadline
  end

  test "the main due date sets the grid, and the first end comes after the minimum term" do
    # Bound until 14 March 2026, so the year-end before that is not an option.
    contract = build(started_on: Date.new(2025, 3, 15), minimum_term_months: 12, renewal_period_months: 12,
                     renewal_anchor_on: Date.new(2026, 1, 1), notice: [ 1, "months" ], anchor: "end_of_term")

    result = schedule(contract, Date.new(2025, 4, 1))

    assert_equal Date.new(2026, 12, 31), result.term_ends_on
    assert_equal Date.new(2026, 11, 30), result.notice_deadline
  end

  test "a phone contract: notice to catch the end of the minimum term" do
    contract = build(started_on: Date.new(2025, 3, 1), minimum_term_months: 24, notice: [ 1, "months" ], anchor: "any_day")

    result = schedule(contract, Date.new(2026, 5, 1))

    assert_equal Date.new(2027, 2, 28), result.term_ends_on
    # One month to the end of February: by the end of January.
    assert_equal Date.new(2027, 1, 31), result.notice_deadline
  end

  test "past the minimum term an indefinite contract has no deadline" do
    contract = build(started_on: Date.new(2022, 3, 1), minimum_term_months: 24, notice: [ 1, "months" ], anchor: "any_day")

    result = schedule(contract, Date.new(2026, 5, 10))

    assert_nil result.notice_deadline
    assert_equal Date.new(2026, 6, 10), result.earliest_end_on
  end

  test "end of month notice lands on a month end" do
    contract = build(notice: [ 3, "months" ], anchor: "end_of_month")

    result = schedule(contract, Date.new(2026, 5, 10))

    assert_nil result.notice_deadline
    assert_equal Date.new(2026, 8, 31), result.earliest_end_on
  end

  test "weeks and days" do
    weeks = build(notice: [ 2, "weeks" ], anchor: "any_day")
    days = build(notice: [ 10, "days" ], anchor: "any_day")

    assert_equal Date.new(2026, 5, 24), schedule(weeks, Date.new(2026, 5, 10)).earliest_end_on
    assert_equal Date.new(2026, 5, 20), schedule(days, Date.new(2026, 5, 10)).earliest_end_on
  end

  test "no notice period recorded: term end but no deadline" do
    contract = build(started_on: Date.new(2024, 1, 1), minimum_term_months: 12, renewal_period_months: 12)

    result = schedule(contract, Date.new(2026, 6, 1))

    assert_equal Date.new(2026, 12, 31), result.term_ends_on
    assert_nil result.notice_deadline
  end

  test "a cancelled or fixed-term contract has nothing to miss" do
    cancelled = build(started_on: Date.new(2024, 1, 1), minimum_term_months: 12, renewal_period_months: 12,
                      notice: [ 3, "months" ], anchor: "end_of_term")
    cancelled.status = "cancellation_sent"
    fixed = build(notice: [ 1, "months" ], anchor: "end_of_term")
    fixed.ends_on = Date.new(2026, 12, 31)

    assert_nil schedule(cancelled, Date.new(2026, 6, 1)).notice_deadline
    assert_nil schedule(fixed, Date.new(2026, 6, 1)).notice_deadline
    assert_equal Date.new(2026, 12, 31), schedule(fixed, Date.new(2026, 6, 1)).term_ends_on
  end

  test "end of February is handled" do
    contract = build(started_on: Date.new(2024, 3, 1), minimum_term_months: 12, renewal_period_months: 12,
                     notice: [ 1, "months" ], anchor: "end_of_term")

    result = schedule(contract, Date.new(2027, 1, 1))

    assert_equal Date.new(2027, 2, 28), result.term_ends_on
    assert_equal Date.new(2027, 1, 31), result.notice_deadline
  end

  test "German defaults are offered for Germany only" do
    assert Contract::LegalDefaults.available_for?("DE")
    assert_not Contract::LegalDefaults.available_for?("US")
    assert_equal 3, Contract::LegalDefaults.for(kind: "insurance", country: "de")[:notice_period_value]
    assert_nil Contract::LegalDefaults.for(kind: "streaming", country: "DE")
  end

  private

    def build(started_on: nil, minimum_term_months: nil, renewal_period_months: nil, renewal_anchor_on: nil, notice: nil, anchor: nil)
      @family.contracts.new(
        name: "Test", provider_name: "Provider", owner: users(:family_admin), status: "active",
        started_on: started_on, minimum_term_months: minimum_term_months,
        renewal_period_months: renewal_period_months, renewal_anchor_on: renewal_anchor_on,
        notice_period_value: notice&.first, notice_period_unit: notice&.last, notice_anchor: anchor
      )
    end

    def schedule(contract, today)
      Contract::NoticeSchedule.new(contract, today: today).call
    end
end
