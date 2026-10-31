require "test_helper"

class Insight::Generators::BudgetInsightGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    # Dated today so the spending lands in the current budget month whatever
    # day the suite runs; the fixture entries sit a few days back.
    create_transaction(account: accounts(:depository), amount: 50, category: categories(:food_and_drink))
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current, user: users(:family_admin))
    budget.update!(budgeted_spending: 5_000, expected_income: 7_000)
    budget.budget_categories.each { |bc| bc.update!(budgeted_spending: 1) }
  end

  test "warns about categories over their limit" do
    assert_equal [ "budget_at_risk" ], generate.map(&:insight_type)
  end

  test "says nothing while the family has budgets switched off" do
    @family.update!(budgets_enabled: false)

    assert_empty generate
  end

  private
    def generate
      Insight::Generators::BudgetInsightGenerator.new(@family).generate
    end
end
