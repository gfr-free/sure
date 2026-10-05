# frozen_string_literal: true

# Custom account subtypes: a family names its own subtype for an account type
# and picks the rules it brings (availability, tax treatment). Accounts point
# at one optionally; it then takes precedence over the built-in subtype's
# rules. See CustomAccountSubtype and docs/llm-guides/account-availability.md.
#
# Sure imports resolve references across chunks through import source
# mappings, so the mapping type list learns the new record type.
class CreateCustomAccountSubtypes < ActiveRecord::Migration[8.1]
  MAPPING_TYPES = %w[Account Category Tag Merchant RecurringTransaction RecurringOccurrence Transaction Budget Security Rule].freeze

  def up
    create_table :custom_account_subtypes, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :accountable_type, null: false
      t.string :name, null: false
      t.jsonb :rules, null: false, default: {}

      t.timestamps
    end

    add_index :custom_account_subtypes, "family_id, accountable_type, lower(name)",
              unique: true, name: "index_custom_account_subtypes_on_family_type_and_name"

    add_reference :accounts, :custom_account_subtype, type: :uuid, null: true,
                  foreign_key: { on_delete: :nullify }

    replace_mapping_type_constraints([ "CustomAccountSubtype", *MAPPING_TYPES ])
  end

  def down
    execute "DELETE FROM import_source_mappings WHERE source_type = 'CustomAccountSubtype' OR target_type = 'CustomAccountSubtype'"
    replace_mapping_type_constraints(MAPPING_TYPES)

    remove_reference :accounts, :custom_account_subtype, foreign_key: true
    drop_table :custom_account_subtypes
  end

  private
    def replace_mapping_type_constraints(types)
      list = types.map { |type| connection.quote(type) }.join(", ")

      %w[source_type target_type].each do |column|
        name = "chk_import_source_mappings_#{column}"
        remove_check_constraint :import_source_mappings, name: name
        add_check_constraint :import_source_mappings, "#{column} IN (#{list})", name: name
      end
    end
end
