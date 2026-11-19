require "test_helper"

class PeriodTest < ActiveSupport::TestCase
  test "raises validation error when start_date or end_date is missing" do
    error = assert_raises(ActiveModel::ValidationError) do
      Period.new(start_date: nil, end_date: nil)
    end

    assert_includes error.message, "Start date can't be blank"
    assert_includes error.message, "End date can't be blank"
  end

  test "raises validation error when start_date is not before end_date" do
    error = assert_raises(ActiveModel::ValidationError) do
      Period.new(start_date: Date.current, end_date: Date.current - 1.day)
    end

    assert_includes error.message, "Start date must be before end date"
  end

  test "can create custom period" do
    period = Period.new(start_date: Date.current - 15.days, end_date: Date.current)
    assert_equal "Custom Period", period.label
  end

  test "from_key returns period for valid key" do
    period = Period.from_key("last_30_days")
    assert_equal 30.days.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "from_key with invalid key and no fallback raises error" do
    error = assert_raises(Period::InvalidKeyError) do
      Period.from_key("invalid_key")
    end
  end

  test "label returns correct label for known period" do
    period = Period.from_key("last_30_days")
    assert_equal "Last 30 Days", period.label
  end

  test "label returns Custom Period for unknown period" do
    period = Period.new(start_date: Date.current - 15.days, end_date: Date.current)
    assert_equal "Custom Period", period.label
  end

  test "label_range omits the year for a range inside the current year" do
    period = Period.custom(
      start_date: Date.new(Date.current.year, 6, 1),
      end_date: Date.new(Date.current.year, 6, 15)
    )

    assert_equal "Jun 01 – Jun 15", period.label_range
  end

  test "label_range includes the year when the range leaves the current year" do
    period = Period.custom(start_date: Date.new(2020, 12, 20), end_date: Date.new(2021, 1, 5))

    assert_equal "Dec 20, 2020 – Jan 05, 2021", period.label_range
  end

  test "comparison_label spells out a custom range" do
    period = Period.custom(start_date: Date.new(2020, 12, 20), end_date: Date.new(2021, 1, 5))

    assert_equal "Dec 20, 2020 to Jan 05, 2021", period.comparison_label
  end

  # Both of these read the month name out of the locale rather than out of a
  # strftime format string, so they would regress to English month abbreviations
  # (and an English "to") the moment either one goes back to `strftime`.
  test "label_range and comparison_label localize month names and date order" do
    period = Period.custom(start_date: Date.new(2020, 12, 20), end_date: Date.new(2021, 1, 5))

    I18n.with_locale(:fr) do
      assert_equal "20 déc. 2020 – 5 jan. 2021", period.label_range
      assert_equal "20 déc. 2020 au 5 jan. 2021", period.comparison_label
    end
  end

  test "label_range localizes the year-less range too" do
    period = Period.custom(
      start_date: Date.new(Date.current.year, 6, 1),
      end_date: Date.new(Date.current.year, 6, 15)
    )

    I18n.with_locale(:fr) do
      assert_equal "1 juin – 15 juin", period.label_range
    end
  end

  test "all_time period can be created" do
    period = Period.from_key("all_time")
    assert_equal "all_time", period.key
    assert_equal "All Time", period.label
    assert_equal "All", period.label_short
  end

  test "all_time period uses family's earliest activity date, starting one month before" do
    # Mock Current.family to return a family with earliest_activity_date
    mock_family = mock("family")
    mock_family.expects(:earliest_activity_date).returns(2.years.ago.to_date)
    Current.expects(:family).at_least_once.returns(mock_family)

    period = Period.from_key("all_time")
    assert_equal 2.years.ago.to_date - 1.month, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "current_month_for preserves the current_month key for custom-month families" do
    family = mock("family")
    family.stubs(:uses_custom_month_start?).returns(true)
    family.stubs(:current_custom_month_period).returns(
      Period.custom(start_date: Date.new(2026, 6, 5), end_date: Date.new(2026, 7, 4))
    )

    period = Period.current_month_for(family)
    assert_equal "current_month", period.key
    assert_equal Date.new(2026, 6, 5), period.start_date
    assert_equal Date.new(2026, 7, 4), period.end_date
  end

  test "last_month_for preserves the last_month key for custom-month families" do
    family = mock("family")
    family.stubs(:uses_custom_month_start?).returns(true)
    family.stubs(:custom_month_start_for).returns(Date.new(2026, 5, 5))
    family.stubs(:custom_month_end_for).returns(Date.new(2026, 6, 4))

    period = Period.last_month_for(family)
    assert_equal "last_month", period.key
  end

  test "all_time period uses fallback when no family or entries exist" do
    Current.expects(:family).returns(nil)

    period = Period.from_key("all_time")
    assert_equal 5.years.ago.to_date, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "all_time period anchors one month back when first activity is today" do
    # A family whose first Transaction is today still anchors to real activity
    # (one month back), not to the 5-year fallback (#4007).
    family = families(:empty)
    account = family.accounts.create!(name: "Checking", balance: 0, currency: "USD", accountable: Depository.new)
    account.entries.create!(date: Date.current, name: "First transaction",
                            amount: -50, currency: "USD", entryable: Transaction.new)

    Current.stubs(:family).returns(family)
    period = Period.from_key("all_time")

    assert_equal Date.current - 1.month, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "all_time period ignores old valuations, starting one month before first transaction" do
    family = families(:empty)
    account = family.accounts.create!(name: "Checking", balance: 0, currency: "USD", accountable: Depository.new)
    account.entries.create!(date: Date.new(2000, 1, 15), name: "Old valuation",
                            amount: 5000, currency: "USD", entryable: Valuation.new)
    first_transaction_date = Date.new(2025, 3, 10)
    account.entries.create!(date: first_transaction_date, name: "Groceries",
                            amount: -50, currency: "USD", entryable: Transaction.new)

    Current.stubs(:family).returns(family)
    period = Period.from_key("all_time")

    assert_equal first_transaction_date - 1.month, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "all_time period falls back to oldest entry date for valuation-only families" do
    # A family with only Valuations (no Transaction/Trade) keeps today's
    # behaviour: the range starts exactly at the oldest entry date (#4007).
    family = families(:empty)
    account = family.accounts.create!(name: "House", balance: 0, currency: "USD", accountable: Depository.new)
    valuation_date = Date.new(2000, 1, 15)
    account.entries.create!(date: valuation_date, name: "Old valuation",
                            amount: 5000, currency: "USD", entryable: Valuation.new)

    Current.stubs(:family).returns(family)
    period = Period.from_key("all_time")

    assert_equal valuation_date, period.start_date
    assert_equal Date.current, period.end_date
  end

  test "current_year is the calendar year to date without a fiscal year" do
    Current.stubs(:family).returns(families(:dylan_family))

    travel_to Date.new(2026, 11, 19) do
      period = Period.from_key("current_year")
      assert_equal Date.new(2026, 1, 1), period.start_date
      assert_equal Date.new(2026, 11, 19), period.end_date
      assert_equal "YTD", period.label_short
    end
  end

  test "current_year follows the family's fiscal year and says so" do
    family = families(:dylan_family)
    family.update!(fiscal_year_start_month: 4)
    Current.stubs(:family).returns(family)

    travel_to Date.new(2026, 2, 10) do
      period = Period.from_key("current_year")
      assert_equal "current_year", period.key
      assert_equal Date.new(2025, 4, 1), period.start_date
      assert_equal Date.new(2026, 2, 10), period.end_date
      assert_equal "FYTD", period.label_short
      assert_equal "Current Fiscal Year", period.label
      assert_equal "vs. start of fiscal year", period.comparison_label
    end
  end

  test "current_year without a family falls back to the calendar year" do
    Current.stubs(:family).returns(nil)

    travel_to Date.new(2026, 11, 19) do
      assert_equal Date.new(2026, 1, 1), Period.from_key("current_year").start_date
    end
  end

  test "from_key_for uses the given family's fiscal year without Current.family" do
    family = families(:dylan_family)
    family.fiscal_year_start_month = 7
    Current.stubs(:family).returns(nil)

    travel_to Date.new(2026, 11, 19) do
      assert_equal Date.new(2026, 7, 1), Period.from_key_for("current_year", family).start_date
      assert_equal Date.new(2026, 11, 19), Period.from_key_for("current_year", family).end_date
      assert_equal "FYTD", Period.from_key_for("current_year", family).label_short
      assert_equal Period.from_key("last_30_days").start_date, Period.from_key_for("last_30_days", family).start_date
    end
  end
end
