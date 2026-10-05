require "test_helper"

class Insight::Generators::InterestRateDropGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @account.update!(balance: 20_000)
    @today = Account.liquidity_today_for(@family)
    @account.interest_rates.create!(effective_from: @today - 60, rate: 3.5)
  end

  test "warns before a teaser rate ends, with what it costs per month" do
    @account.interest_rates.create!(effective_from: @today + 10, rate: 1.5)

    insights = Insight::Generators::InterestRateDropGenerator.new(@family).generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "interest_rate_drop", insight.insight_type
    assert_equal @account.id, insight.metadata[:account_id]
    assert_equal "interest_rate_drop:#{@account.id}:#{(@today + 10).iso8601}", insight.dedup_key
    # 20,000 x 2 % / 12
    assert_equal Money.new(33.33, "USD").format, insight.facts[:monthly_loss]
    assert_includes I18n.t("insights.templates.#{insight.template_key}", **insight.facts), @account.name
  end

  test "stays quiet for rises, changes further out and accounts without interest" do
    @account.interest_rates.create!(effective_from: @today + 5, rate: 4)
    @account.interest_rates.create!(effective_from: @today + 40, rate: 1)

    assert_empty Insight::Generators::InterestRateDropGenerator.new(@family).generate
  end
end
