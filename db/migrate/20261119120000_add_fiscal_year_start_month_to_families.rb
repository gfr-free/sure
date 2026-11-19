class AddFiscalYearStartMonthToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :fiscal_year_start_month, :integer, default: 1, null: false
    add_check_constraint :families, "fiscal_year_start_month >= 1 AND fiscal_year_start_month <= 12", name: "fiscal_year_start_month_range"
  end
end
