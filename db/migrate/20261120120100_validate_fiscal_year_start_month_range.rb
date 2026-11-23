# Validates the check constraint AddFiscalYearStartMonthToFamilies added as NOT
# VALID, in its own migration so the table scan runs after the lock from adding
# the constraint has been released.
class ValidateFiscalYearStartMonthRange < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :families, name: "fiscal_year_start_month_range"
  end

  # A validated constraint can't be marked NOT VALID again; rolling back the
  # previous migration removes it entirely.
  def down
  end
end
