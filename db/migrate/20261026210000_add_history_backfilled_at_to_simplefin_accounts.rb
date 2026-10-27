class AddHistoryBackfilledAtToSimplefinAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :simplefin_accounts, :history_backfilled_at, :datetime
  end
end
