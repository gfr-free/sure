class AddQrIdentifiersToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :merchant_identifiers, :jsonb, null: false, default: []

    create_table :receipt_merchant_hints, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.references :merchant, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :kind, null: false, limit: 20
      t.string :value, null: false, limit: 200
      t.timestamps
    end

    add_index :receipt_merchant_hints, [ :family_id, :kind, :value ], unique: true
  end
end
