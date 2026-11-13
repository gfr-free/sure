class CreateBullionSpecs < ActiveRecord::Migration[8.1]
  def change
    create_table :bullion_specs, id: :uuid do |t|
      t.references :security, null: false, type: :uuid, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :family, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :metal, null: false
      t.decimal :fine_weight_grams, precision: 12, scale: 4, null: false
      t.string :catalog_key
      t.string :size_key

      t.timestamps
    end

    add_index :bullion_specs, %i[catalog_key size_key], unique: true, where: "family_id IS NULL",
              name: "index_bullion_specs_on_catalog_product"
    add_check_constraint :bullion_specs, "metal IN ('XAU', 'XAG', 'XPT', 'XPD')", name: "chk_bullion_specs_metal"
    add_check_constraint :bullion_specs, "fine_weight_grams > 0", name: "chk_bullion_specs_fine_weight_positive"
    add_check_constraint :bullion_specs,
                         "(family_id IS NULL AND catalog_key IS NOT NULL AND size_key IS NOT NULL) OR " \
                         "(family_id IS NOT NULL AND catalog_key IS NULL AND size_key IS NULL)",
                         name: "chk_bullion_specs_catalog_or_custom"
  end
end
