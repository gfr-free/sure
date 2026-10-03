# Family::DataImporter records a source mapping for every imported contract, so
# the mapping type constraints have to allow Contract, as ImportSourceMapping's
# SOURCE_TYPES already does.
class AllowContractImportSourceMappings < ActiveRecord::Migration[8.1]
  WITH_CONTRACT = %w[Account Category Tag Merchant Contract RecurringTransaction RecurringOccurrence Transaction Budget Security Rule].freeze
  WITHOUT_CONTRACT = (WITH_CONTRACT - %w[Contract]).freeze

  def up
    replace_type_constraints(WITH_CONTRACT)
  end

  def down
    execute "DELETE FROM import_source_mappings WHERE source_type = 'Contract' OR target_type = 'Contract'"
    replace_type_constraints(WITHOUT_CONTRACT)
  end

  private
    def replace_type_constraints(types)
      list = types.map { |type| connection.quote(type) }.join(", ")

      %w[source_type target_type].each do |column|
        remove_check_constraint :import_source_mappings, name: "chk_import_source_mappings_#{column}"
        add_check_constraint :import_source_mappings, "#{column} IN (#{list})", name: "chk_import_source_mappings_#{column}"
      end
    end
end
