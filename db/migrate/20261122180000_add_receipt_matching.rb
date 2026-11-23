class AddReceiptMatching < ActiveRecord::Migration[8.1]
  def change
    # pending: Sure linked the receipt on its own and waits for the uploader to
    # confirm or reject; confirmed: the uploader linked or confirmed it.
    add_column :receipts, :match_status, :string, limit: 20

    reversible do |dir|
      dir.up { execute "UPDATE receipts SET match_status = 'confirmed' WHERE transaction_id IS NOT NULL" }
    end

    create_table :rejected_receipt_matches, id: :uuid do |t|
      t.references :receipt, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.references :transaction, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.timestamps
    end
    add_index :rejected_receipt_matches, [ :receipt_id, :transaction_id ], unique: true, name: "index_rejected_receipt_matches_on_receipt_and_transaction"

    add_column :families, :receipt_bank_wait_days, :integer, null: false, default: 7
  end
end
