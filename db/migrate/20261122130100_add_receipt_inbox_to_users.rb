class AddReceiptInboxToUsers < ActiveRecord::Migration[8.1]
  def change
    # Both are encrypted when Active Record encryption is configured: the token
    # deterministically, so the inbox can look it up.
    add_column :users, :receipt_inbox_token, :string
    add_column :users, :receipt_inbox_senders, :text
    add_index :users, :receipt_inbox_token, unique: true
  end
end
