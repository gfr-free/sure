class AddBalanceUnambiguousToEnableBankingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_accounts, :balance_unambiguous, :boolean, default: false, null: false
  end
end
