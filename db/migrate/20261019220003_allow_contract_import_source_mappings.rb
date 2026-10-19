# Family::DataImporter records a source mapping for every imported contract, so
# the mapping type constraints have to allow Contract, as ImportSourceMapping's
# SOURCE_TYPES already does.
#
# The allowed types are read from the existing constraints instead of being
# hard-coded, so types added by other migrations are kept in both directions.
class AllowContractImportSourceMappings < ActiveRecord::Migration[8.1]
  TYPE = "Contract".freeze
  COLUMNS = %w[source_type target_type].freeze

  def up
    COLUMNS.each do |column|
      types = allowed_types(column)
      next if types.nil? || types.include?(TYPE)

      position = types.index("Merchant")
      position = position ? position + 1 : types.size
      replace_type_constraint(column, types.dup.insert(position, TYPE))
    end
  end

  def down
    execute "DELETE FROM import_source_mappings WHERE source_type = #{connection.quote(TYPE)} OR target_type = #{connection.quote(TYPE)}"

    COLUMNS.each do |column|
      types = allowed_types(column)
      next if types.nil? || !types.include?(TYPE)

      replace_type_constraint(column, types - [ TYPE ])
    end
  end

  private
    def constraint_name(column)
      "chk_import_source_mappings_#{column}"
    end

    # Returns the type names listed in the column's check constraint, in their
    # current order, or nil when the constraint does not exist.
    def allowed_types(column)
      definition = select_value(<<~SQL.squish)
        SELECT pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conrelid = 'import_source_mappings'::regclass
          AND conname = #{connection.quote(constraint_name(column))}
      SQL

      definition&.scan(/'([^']+)'/)&.flatten
    end

    def replace_type_constraint(column, types)
      list = types.map { |type| connection.quote(type) }.join(", ")

      remove_check_constraint :import_source_mappings, name: constraint_name(column)
      add_check_constraint :import_source_mappings, "#{column} IN (#{list})", name: constraint_name(column)
    end
end
