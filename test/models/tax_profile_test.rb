require "test_helper"

class TaxProfileTest < ActiveSupport::TestCase
  setup do
    @user = users(:empty)
  end

  test "the profile in force is the latest one starting on or before the year" do
    old = @user.tax_profiles.create!(valid_from_year: 2024, currency: "EUR", rate_interest: 25)
    current = @user.tax_profiles.create!(valid_from_year: 2026, currency: "EUR", rate_interest: 26.375)

    assert_nil TaxProfile.for(@user, 2023)
    assert_equal old, TaxProfile.for(@user, 2025)
    assert_equal current, TaxProfile.for(@user, 2026)
    assert_equal current, TaxProfile.for(@user, 2030)
  end

  test "rates stay within 0 and 100 and may be empty" do
    profile = @user.tax_profiles.build(valid_from_year: 2026, currency: "EUR")
    assert profile.valid?
    assert_not profile.rates?

    profile.rate_dividends = 101
    assert_not profile.valid?

    profile.rate_dividends = 0
    assert profile.valid?
    assert profile.rates?
  end

  test "the currency must be a known one" do
    assert_not @user.tax_profiles.build(valid_from_year: 2026, currency: "XYZ").valid?
  end

  test "one profile per person and year" do
    @user.tax_profiles.create!(valid_from_year: 2026, currency: "EUR")

    assert_not @user.tax_profiles.build(valid_from_year: 2026, currency: "EUR").valid?
  end

  test "rate_for rejects unknown kinds" do
    profile = @user.tax_profiles.build(valid_from_year: 2026, currency: "EUR", rate_interest: 20)

    assert_equal 20, profile.rate_for("interest")
    assert_raises(ArgumentError) { profile.rate_for("salary") }
  end

  test "settling a year's reserve is stored per person" do
    @user.settle_tax_reserve!(2025)
    assert @user.reload.tax_reserve_settled?(2025)
    assert_not @user.tax_reserve_settled?(2026)

    @user.settle_tax_reserve!(2025, settled: false)
    assert_not @user.reload.tax_reserve_settled?(2025)
  end
end
