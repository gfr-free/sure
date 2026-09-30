class CreateSecuritySplits < ActiveRecord::Migration[8.1]
  def change
    create_table :security_splits, id: :uuid do |t|
      t.references :security, null: false, type: :uuid, index: false, foreign_key: { on_delete: :cascade }
      # NULL for splits a price provider reported, which apply to every family.
      # A family's own entries apply to that family only.
      t.references :family, type: :uuid, foreign_key: { on_delete: :cascade }
      t.date :date, null: false
      t.decimal :ratio_from, precision: 19, scale: 8, null: false
      t.decimal :ratio_to, precision: 19, scale: 8, null: false
      t.string :source, null: false
      t.timestamps
    end

    add_index :security_splits, %i[security_id date],
              unique: true, where: "family_id IS NULL", name: "index_security_splits_on_provider_split"
    add_index :security_splits, %i[security_id family_id date],
              unique: true, where: "family_id IS NOT NULL", name: "index_security_splits_on_family_split"
    add_check_constraint :security_splits, "ratio_from > 0 AND ratio_to > 0", name: "chk_security_splits_positive_ratio"
    add_check_constraint :security_splits, "source IN ('provider', 'manual')", name: "chk_security_splits_source"

    add_column :securities, :splits_checked_at, :datetime
  end
end
