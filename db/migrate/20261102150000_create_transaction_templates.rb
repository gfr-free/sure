class CreateTransactionTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :transaction_templates, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :name, null: false
      t.string :nature, null: false, default: "outflow"
      t.decimal :amount, precision: 19, scale: 4
      t.string :currency
      t.references :account, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :category, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :merchant, foreign_key: { on_delete: :nullify }, type: :uuid
      t.text :notes

      t.timestamps
    end
  end
end
