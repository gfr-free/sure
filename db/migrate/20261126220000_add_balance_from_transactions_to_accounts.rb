class AddBalanceFromTransactionsToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :balance_from_transactions_since, :date
    add_column :accounts, :balance_from_transactions_start_cash, :decimal, precision: 19, scale: 4
    add_column :accounts, :balance_from_transactions_start_non_cash, :decimal, precision: 19, scale: 4
    add_column :accounts, :balance_from_transactions_ledger_total, :decimal, precision: 19, scale: 4
  end
end
