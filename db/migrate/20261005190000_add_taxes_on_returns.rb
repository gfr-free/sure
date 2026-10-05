# frozen_string_literal: true

# Taxes on returns (liquidity concept, decision E20, STEUER.md step S-1/S-2).
#
# - `tax_profiles`: per person (user) and from a year on, a rate per income
#   type, the yearly allowance and whether banks usually withhold the tax.
#   Every value is entered by the person; there are no country presets (S5).
# - `depositories.tax_treatment`: bank accounts can be taxable, tax-exempt
#   and so on, like crypto accounts. Nil follows the subtype.
# - `accounts.tax_withheld_at_source`: nil follows the owner's profile.
# - `accounts.tax_allowance_allocation`: the share of the allowance given to
#   this account's bank (exemption order).
# - `accounts.january_tax_debit`: a tax the bank debits every January, such as
#   the German Vorabpauschale (S7), entered by hand.
#
# Purely additive: no backfill. Without a profile Sure keeps showing gross
# figures everywhere.
class AddTaxesOnReturns < ActiveRecord::Migration[8.1]
  def change
    create_table :tax_profiles, id: :uuid do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.integer :valid_from_year, null: false
      t.string :currency, null: false
      t.decimal :rate_interest, precision: 6, scale: 3
      t.decimal :rate_dividends, precision: 6, scale: 3
      t.decimal :rate_gains, precision: 6, scale: 3
      t.decimal :rate_crypto, precision: 6, scale: 3
      t.decimal :annual_allowance, precision: 19, scale: 4
      t.boolean :withheld_at_source_default, null: false, default: true

      t.timestamps
    end

    add_index :tax_profiles, [ :user_id, :valid_from_year ], unique: true
    %w[rate_interest rate_dividends rate_gains rate_crypto].each do |column|
      add_check_constraint :tax_profiles, "#{column} IS NULL OR (#{column} >= 0 AND #{column} <= 100)",
                           name: "chk_tax_profiles_#{column}"
    end
    add_check_constraint :tax_profiles, "annual_allowance IS NULL OR annual_allowance >= 0",
                         name: "chk_tax_profiles_annual_allowance"

    add_column :depositories, :tax_treatment, :string
    add_check_constraint :depositories,
                         "tax_treatment IS NULL OR tax_treatment IN ('taxable', 'tax_deferred', 'tax_exempt', 'tax_advantaged')",
                         name: "chk_depositories_tax_treatment"

    add_column :accounts, :tax_withheld_at_source, :boolean
    add_column :accounts, :tax_allowance_allocation, :decimal, precision: 19, scale: 4
    add_column :accounts, :january_tax_debit, :decimal, precision: 19, scale: 4
    add_check_constraint :accounts, "tax_allowance_allocation IS NULL OR tax_allowance_allocation >= 0",
                         name: "chk_accounts_tax_allowance_allocation"
    add_check_constraint :accounts, "january_tax_debit IS NULL OR january_tax_debit >= 0",
                         name: "chk_accounts_january_tax_debit"
  end
end
