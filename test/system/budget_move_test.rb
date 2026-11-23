require "application_system_test_case"

# The row's move button hands the dialog its source through Stimulus action
# params, so only a browser can tell whether the button and the dialog still
# agree on them.
class BudgetMoveTest < ApplicationSystemTestCase
  setup do
    @budget = budgets(:one)
    family = @budget.family

    groceries = Category.create!(name: "Move test groceries", family: family, color: "#4da568")
    transport = Category.create!(name: "Move test transport", family: family, color: "#e99537")
    @source = BudgetCategory.create!(budget: @budget, category: groceries, budgeted_spending: 300, currency: @budget.currency)
    @destination = BudgetCategory.create!(budget: @budget, category: transport, budgeted_spending: 0, currency: @budget.currency)

    sign_in users(:family_admin)
  end

  test "the move button opens the dialog for its own row" do
    visit budget_budget_categories_path(@budget)

    within "##{ActionView::RecordIdentifier.dom_id(@source, :form)}" do
      click_button I18n.t("budget_categories.move.button_title")
    end

    within "dialog[open]" do
      assert_text "Move test groceries"
      assert_text @source.budgeted_spending_money.format
      assert_equal @destination.id, find("select[data-budget-move-target='toSelect']").value
      assert find("option[value='#{@source.id}']", visible: :all).disabled?
    end
  end
end
