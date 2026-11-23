class AddFeatureTogglesForBudgetsAndPlanToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :budgets_enabled, :boolean, default: true, null: false
    add_column :families, :plan_enabled, :boolean, default: true, null: false
  end
end
