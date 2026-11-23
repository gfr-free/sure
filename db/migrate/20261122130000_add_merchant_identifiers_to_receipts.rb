class AddMerchantIdentifiersToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :merchant_identifiers, :jsonb, null: false, default: []
    add_index :receipts, :merchant_identifiers, using: :gin
  end
end
