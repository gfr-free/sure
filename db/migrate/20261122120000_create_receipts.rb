class CreateReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :receipts, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :uploaded_by, foreign_key: { to_table: :users, on_delete: :nullify }, type: :uuid, index: false
      t.references :transaction, foreign_key: { on_delete: :nullify }, type: :uuid
      t.string :source, null: false, default: "web"
      t.string :extraction_status, null: false, default: "pending"
      t.string :extraction_error, limit: 100
      t.string :filename, null: false, limit: 255
      t.string :content_type, null: false, limit: 100
      t.bigint :byte_size, null: false
      t.string :content_sha256, null: false, limit: 64
      t.string :merchant_name, limit: 200
      t.date :date
      t.decimal :amount, precision: 19, scale: 4
      t.string :currency, limit: 3
      t.jsonb :field_sources, null: false, default: {}
      t.text :raw_text
      t.boolean :created_transaction, null: false, default: false
      t.datetime :linked_at
      t.datetime :dismissed_at
      t.timestamps
    end

    # Receipts are private to their uploader, so only the uploader's own copy is a duplicate.
    add_index :receipts, [ :uploaded_by_id, :content_sha256 ], unique: true
    add_index :receipts, [ :uploaded_by_id, :created_at ]
  end
end
