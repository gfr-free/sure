class ValidateFiscalYearStartMonthRange < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :families, name: "fiscal_year_start_month_range"
  end
end
