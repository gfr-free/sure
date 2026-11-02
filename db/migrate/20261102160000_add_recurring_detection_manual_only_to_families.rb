class AddRecurringDetectionManualOnlyToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :recurring_detection_manual_only, :boolean, default: false, null: false
  end
end
