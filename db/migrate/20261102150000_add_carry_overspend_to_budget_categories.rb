class AddCarryOverspendToBudgetCategories < ActiveRecord::Migration[8.1]
  def up
    add_column :budget_categories, :carry_overspend, :boolean, null: false, default: false

    # A negative carry is now a choice the envelope makes. Without that
    # choice it would still quietly shrink `available_to_spend`, so the
    # database keeps refusing it everywhere else.
    remove_check_constraint :budget_categories, name: "chk_budget_categories_rolled_over_amount_non_negative"
    add_check_constraint :budget_categories, "rolled_over_amount >= 0 OR carry_overspend",
                         name: "chk_budget_categories_rolled_over_amount_non_negative"
  end

  def down
    # Rolling back means forfeiting every carried overspend, which is the
    # behaviour the older schema can represent.
    execute "UPDATE budget_categories SET rolled_over_amount = 0 WHERE rolled_over_amount < 0"

    remove_check_constraint :budget_categories, name: "chk_budget_categories_rolled_over_amount_non_negative"
    add_check_constraint :budget_categories, "rolled_over_amount >= 0",
                         name: "chk_budget_categories_rolled_over_amount_non_negative"

    remove_column :budget_categories, :carry_overspend
  end
end
