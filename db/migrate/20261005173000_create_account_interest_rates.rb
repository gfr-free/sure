# frozen_string_literal: true

# Interest terms on accounts (liquidity concept, decision E18: the slim first
# step of the interest sub-concept).
#
# `account_interest_rates` keeps the rate history, including planned changes
# such as a teaser rate that ends on a date. `applies_to` separates the credit
# rate (paid on a positive balance) from the debit rate (charged on an
# overdraft). `interest_payout_frequency` says how often the interest is paid
# into the account; nil means the account has no interest terms.
#
# Purely additive: no backfill, existing accounts keep behaving as before.
class CreateAccountInterestRates < ActiveRecord::Migration[8.1]
  def change
    create_table :account_interest_rates, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.date :effective_from, null: false
      t.decimal :rate, precision: 8, scale: 4, null: false
      t.string :applies_to, null: false, default: "credit"
      t.string :source, null: false, default: "manual"

      t.timestamps
    end

    add_index :account_interest_rates, [ :account_id, :applies_to, :effective_from ],
              unique: true, name: "index_account_interest_rates_on_account_kind_date"
    add_check_constraint :account_interest_rates, "applies_to IN ('credit', 'debit')",
                         name: "chk_account_interest_rates_applies_to"
    add_check_constraint :account_interest_rates, "source IN ('manual', 'provider')",
                         name: "chk_account_interest_rates_source"
    add_check_constraint :account_interest_rates, "rate > -100 AND rate < 1000",
                         name: "chk_account_interest_rates_rate"

    add_column :accounts, :interest_payout_frequency, :string
    add_check_constraint :accounts,
                         "interest_payout_frequency IS NULL OR interest_payout_frequency IN " \
                         "('daily', 'monthly', 'quarterly', 'semiannual', 'annual', 'at_maturity')",
                         name: "chk_accounts_interest_payout_frequency"
  end
end
