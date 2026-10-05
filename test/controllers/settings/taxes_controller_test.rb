require "test_helper"

class Settings::TaxesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @year = Account.liquidity_today_for(@user.family).year
  end

  test "is preview only" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get settings_taxes_path

    assert_redirected_to root_path
  end

  test "shows an empty profile for this year" do
    get settings_taxes_path

    assert_response :success
    assert_select "form[data-testid='tax-profile-form']"
    assert_select "input[name='tax_profile[valid_from_year]'][value='#{@year}']"
    assert_match I18n.t("settings.taxes.show.no_profile", year: @year), response.body
  end

  test "saves the profile for the year it applies from" do
    patch settings_taxes_path, params: {
      tax_profile: { valid_from_year: @year, currency: "EUR", rate_interest: "26.375", rate_dividends: "26.375",
                     annual_allowance: "1000", withheld_at_source_default: "1" }
    }

    assert_redirected_to settings_taxes_path
    profile = @user.tax_profiles.find_by!(valid_from_year: @year)
    assert_equal BigDecimal("26.375"), profile.rate_interest
    assert_equal BigDecimal("1000"), profile.annual_allowance
    assert profile.withheld_at_source_default

    patch settings_taxes_path, params: { tax_profile: { valid_from_year: @year + 1, currency: "EUR", rate_interest: "25" } }

    assert_equal [ @year, @year + 1 ], @user.tax_profiles.chronological.pluck(:valid_from_year)
    assert_equal BigDecimal("26.375"), profile.reload.rate_interest
  end

  test "a rate out of range is not saved" do
    patch settings_taxes_path, params: { tax_profile: { valid_from_year: @year, currency: "EUR", rate_interest: "120" } }

    assert_redirected_to settings_taxes_path
    assert_not_nil flash[:alert]
    assert_empty @user.tax_profiles
  end

  test "marks a year's reserve as paid and open again" do
    post settle_settings_taxes_path(year: @year - 1, settled: true)
    assert @user.reload.tax_reserve_settled?(@year - 1)

    post settle_settings_taxes_path(year: @year - 1, settled: false)
    assert_not @user.reload.tax_reserve_settled?(@year - 1)
  end

  test "removes only the person's own entries" do
    other = users(:family_member).tax_profiles.create!(valid_from_year: @year, currency: "USD")

    delete profile_settings_taxes_path(profile_id: other.id)

    assert_response :not_found
    assert TaxProfile.exists?(other.id)
  end

  test "shows the reserve and the exemption orders per bank" do
    @user.tax_profiles.create!(valid_from_year: @year, currency: "USD", rate_interest: 25, annual_allowance: 1_000)
    account = accounts(:depository)
    account.update!(owner: @user, tax_withheld_at_source: true, tax_allowance_allocation: 100, institution_name: "Demo Bank")
    account.entries.create!(date: Date.new(@year, 1, 2).clamp(..Date.current), amount: -150, currency: "USD", name: "Interest",
                            entryable: Transaction.new(investment_activity_label: "Interest"))

    get settings_taxes_path

    assert_response :success
    assert_select "[data-testid='tax-estimate-#{@year}']"
    assert_match "Demo Bank", response.body
    assert_match I18n.t("settings.taxes.show.used_up"), response.body
  end
end
