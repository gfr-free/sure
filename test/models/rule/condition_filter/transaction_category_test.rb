require "test_helper"

class Rule::ConditionFilter::TransactionCategoryTest < ActiveSupport::TestCase
  setup do
    @rule = rules(:one)
    @filter = Rule::ConditionFilter::TransactionCategory.new(@rule)
  end

  test "options groups subcategories immediately after their parent" do
    options = @filter.options

    parent_index = options.index { |_label, id| id == categories(:food_and_drink).id }
    child_index = options.index { |_label, id| id == categories(:subcategory).id }

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
  end

  test "options indent subcategories below their parent" do
    child_label, = @filter.options.find { |_label, id| id == categories(:subcategory).id }

    assert_equal "↳ #{categories(:subcategory).name}", child_label
  end

  test "value_display shows the subcategory name without the indent arrow" do
    condition = Rule::Condition.new(
      rule: @rule,
      condition_type: "transaction_category",
      operator: "=",
      value: categories(:subcategory).id
    )

    assert_equal categories(:subcategory).name, condition.value_display
  end
end
