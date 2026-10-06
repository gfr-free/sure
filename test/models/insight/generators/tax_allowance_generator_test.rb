require "test_helper"

class Insight::Generators::TaxAllowanceGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @year = Account.liquidity_today_for(@family).year
    @account = accounts(:depository)
    @account.update!(owner: @user, tax_withheld_at_source: true, tax_allowance_allocation: 100, institution_name: "Demo Bank")
  end

  test "stays quiet without a profile" do
    interest(150)

    assert_empty generate
  end

  test "points out an exemption order that is used up" do
    profile(annual_allowance: 1_000)
    interest(150)

    insights = generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "tax_allowance", insight.insight_type
    assert_equal "tax_allowance_used_up", insight.template_key
    assert_equal "Demo Bank", insight.facts[:bank]
    assert_match(/\Atax_allowance_used_up:#{@user.id}:#{@year}:/, insight.dedup_key)
    assert_includes I18n.t("insights.templates.#{insight.template_key}", **insight.facts), "Demo Bank"
  end

  test "points out exemption orders above the allowance" do
    profile(annual_allowance: 50)

    insights = generate

    assert_equal [ "tax_allowance_over_allocated" ], insights.map(&:template_key)
    assert_equal "tax_allowance_over_allocated:#{@user.id}:#{@year}", insights.first.dedup_key
  end

  test "leaves out accounts another family member cannot see" do
    profile(annual_allowance: 1_000)
    interest(150)
    other = users(:family_member)
    @account.account_shares.where(user: other).destroy_all
    assert_not Account.accessible_by(other).exists?(@account.id)

    assert_empty generate.select { |insight| insight.facts[:bank] == "Demo Bank" }
    assert_empty generate.select { |insight| insight.template_key == "tax_allowance_over_allocated" }
  end

  private
    def generate
      Insight::Generators::TaxAllowanceGenerator.new(@family).generate
    end

    def profile(**attributes)
      @user.tax_profiles.create!(valid_from_year: @year, currency: "USD", rate_interest: 25, **attributes)
    end

    def interest(amount)
      @account.entries.create!(date: Date.new(@year, 1, 2).clamp(..Date.current), amount: -amount, currency: "USD", name: "Interest",
                               entryable: Transaction.new(investment_activity_label: "Interest"))
    end
end
