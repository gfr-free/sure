require "test_helper"

class Family::FiscalYearTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "defaults to a January start, which is the calendar year" do
    assert_equal 1, @family.fiscal_year_start_month
    assert_not @family.uses_fiscal_year?
    assert_equal Date.new(2026, 1, 1), @family.fiscal_year_start_for(Date.new(2026, 11, 19))
    assert_equal Date.new(2026, 12, 31), @family.fiscal_year_end_for(Date.new(2026, 11, 19))
    assert_equal "2026", @family.fiscal_year_label(Date.new(2026, 11, 19))
  end

  test "a January start ignores a custom month start day" do
    @family.month_start_day = 25

    assert_equal Date.new(2026, 1, 1), @family.fiscal_year_start_for(Date.new(2026, 1, 10))
  end

  test "validates the start month is between 1 and 12" do
    @family.fiscal_year_start_month = 0
    assert_not @family.valid?
    @family.fiscal_year_start_month = 13
    assert_not @family.valid?
    @family.fiscal_year_start_month = 4
    assert @family.valid?
  end

  test "the database rejects a start month out of range" do
    assert_raises(ActiveRecord::StatementInvalid) do
      @family.update_column(:fiscal_year_start_month, 13)
    end
  end

  test "an April start runs from April to March" do
    @family.fiscal_year_start_month = 4

    assert @family.uses_fiscal_year?
    assert_equal Date.new(2026, 4, 1), @family.fiscal_year_start_for(Date.new(2026, 4, 1))
    assert_equal Date.new(2025, 4, 1), @family.fiscal_year_start_for(Date.new(2026, 3, 31))
    assert_equal Date.new(2027, 3, 31), @family.fiscal_year_end_for(Date.new(2026, 11, 19))
    assert_equal "2026/27", @family.fiscal_year_label(Date.new(2026, 11, 19))
    assert_equal "2025/26", @family.fiscal_year_label(Date.new(2026, 2, 1))
  end

  test "the year opens on the budget month start day" do
    @family.fiscal_year_start_month = 4
    @family.month_start_day = 25

    assert_equal Date.new(2026, 4, 25), @family.fiscal_year_start_for(Date.new(2026, 4, 25))
    assert_equal Date.new(2025, 4, 25), @family.fiscal_year_start_for(Date.new(2026, 4, 24))
    assert_equal Date.new(2027, 4, 24), @family.fiscal_year_end_for(Date.new(2026, 4, 25))
  end

  test "a year ending around a leap day still has 366 or 365 days" do
    @family.fiscal_year_start_month = 3

    assert_equal Date.new(2028, 2, 29), @family.fiscal_year_end_for(Date.new(2027, 6, 1))
    assert_equal Date.new(2027, 2, 28), @family.fiscal_year_end_for(Date.new(2026, 6, 1))
  end

  test "the century label wraps to two digits" do
    @family.fiscal_year_start_month = 7

    assert_equal "2099/00", @family.fiscal_year_label(Date.new(2099, 8, 1))
  end

  test "the fiscal year label follows the locale" do
    @family.fiscal_year_start_month = 4

    I18n.with_locale(:de) { assert_equal "2026/27", @family.fiscal_year_label(Date.new(2026, 5, 1)) }
  end

  test "fiscal quarters count three months from the fiscal year start" do
    @family.fiscal_year_start_month = 4

    assert_equal Date.new(2026, 4, 1), @family.fiscal_quarter_start_for(Date.new(2026, 6, 30))
    assert_equal Date.new(2026, 6, 30), @family.fiscal_quarter_end_for(Date.new(2026, 4, 1))
    assert_equal 1, @family.fiscal_quarter_number(Date.new(2026, 5, 15))
    assert_equal Date.new(2026, 10, 1), @family.fiscal_quarter_start_for(Date.new(2026, 11, 19))
    assert_equal 3, @family.fiscal_quarter_number(Date.new(2026, 11, 19))
    assert_equal Date.new(2027, 1, 1), @family.fiscal_quarter_start_for(Date.new(2027, 3, 31))
    assert_equal 4, @family.fiscal_quarter_number(Date.new(2027, 3, 31))
  end

  test "fiscal quarters follow the month start day" do
    @family.fiscal_year_start_month = 4
    @family.month_start_day = 25

    assert_equal Date.new(2026, 7, 25), @family.fiscal_quarter_start_for(Date.new(2026, 7, 25))
    assert_equal Date.new(2026, 4, 25), @family.fiscal_quarter_start_for(Date.new(2026, 7, 24))
    assert_equal Date.new(2026, 7, 24), @family.fiscal_quarter_end_for(Date.new(2026, 5, 1))
  end

  test "a calendar-year family keeps calendar quarters" do
    assert_equal Date.new(2026, 10, 1), @family.fiscal_quarter_start_for(Date.new(2026, 11, 19))
    assert_equal Date.new(2026, 12, 31), @family.fiscal_quarter_end_for(Date.new(2026, 11, 19))
    assert_equal 4, @family.fiscal_quarter_number(Date.new(2026, 11, 19))
  end
end
