require "test_helper"

class Insight::Generators::AccountShortfallGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @account.update!(balance: 500)
    @today = Account.liquidity_today_for(@family)
    @family.recurring_transactions.destroy_all
  end

  test "warns per account when expected payments take it below zero" do
    add_bill("Rent", 650, @today + 10)

    insights = Insight::Generators::AccountShortfallGenerator.new(@family).generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "account_shortfall", insight.insight_type
    assert_equal "high", insight.priority
    assert_equal @account.id, insight.metadata[:account_id]
    assert_equal "account_shortfall:#{@account.id}:#{@today.strftime("%Y-%m")}", insight.dedup_key
    assert_equal "Rent", insight.facts[:cause]
    assert_equal Money.new(150, "USD").format, insight.facts[:shortfall]
    assert_includes I18n.t("insights.templates.#{insight.template_key}", **insight.facts), @account.name
  end

  test "stays quiet when the account is covered" do
    add_bill("Rent", 400, @today + 10)

    assert_empty Insight::Generators::AccountShortfallGenerator.new(@family).generate
  end

  test "a few cents of drift keep the same bucket" do
    @account.update!(balance: 480)
    add_bill("Rent", 650, @today + 10)
    first = Insight::Generators::AccountShortfallGenerator.new(@family).generate.first

    @account.update!(balance: 479.5)
    second = Insight::Generators::AccountShortfallGenerator.new(@family).generate.first

    assert_equal first.metadata, second.metadata
  end

  test "the family-wide cash flow warning steps back while an account warning stands" do
    add_bill("Rent", 650, @today + 10)

    assert_empty Insight::Generators::CashFlowWarningGenerator.new(@family).generate
  end

  private
    def add_bill(name, amount, due_on)
      series = @family.recurring_transactions.create!(
        name: name, account: @account, amount: amount, currency: "USD", bill_type: "bill",
        expected_day_of_month: 15, last_occurrence_date: @today, next_expected_date: @today + 30,
        status: "active", manual: true
      )
      series.recurring_occurrences.delete_all
      series.recurring_occurrences.create!(family: @family, original_due_on: due_on, due_on: due_on, currency: "USD")
    end
end
