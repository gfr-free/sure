class CreateCounterpartiesAndClearings < ActiveRecord::Migration[8.1]
  def change
    create_table :counterparties, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }, type: :uuid
      t.string :name, null: false
      t.text :note
      t.string :default_currency, null: false
      t.datetime :archived_at
      t.timestamps
    end
    add_index :counterparties, "family_id, lower(name)", unique: true, name: "index_counterparties_on_family_id_and_lower_name"

    create_table :clearings, id: :uuid do |t|
      t.references :counterparty, null: false, foreign_key: true, type: :uuid
      t.jsonb :locked_attributes, default: {}
      t.string :subtype
      t.timestamps
    end
  end
end
