# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260929230008_add_unique_transaction_indexes_to_transfers")

# The index swap builds concurrently, which cannot run inside a transaction, so
# these tests commit their DDL and put the schema's index back afterwards.
class AddUniqueTransactionIndexesToTransfersMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  INDEX = "index_transfers_on_inflow_transaction_id"
  TEMP_INDEX = "#{INDEX}_new"

  setup do
    @migration = AddUniqueTransactionIndexesToTransfers.new
    @migration.verbose = false
  end

  teardown do
    connection.execute("DROP INDEX IF EXISTS #{TEMP_INDEX}")
    unless connection.index_name_exists?(:transfers, INDEX)
      connection.add_index :transfers, :inflow_transaction_id, name: INDEX, unique: true
    end
  end

  # A run that stopped after dropping the old index but before the rename.
  test "a rerun keeps an already built replacement and finishes the swap" do
    connection.rename_index :transfers, INDEX, TEMP_INDEX
    built_oid = index_oid(TEMP_INDEX)

    @migration.send(:replace_index, :inflow_transaction_id, unique: true)

    assert_equal built_oid, index_oid(INDEX), "the finished replacement was dropped and rebuilt"
    assert_not connection.index_name_exists?(:transfers, TEMP_INDEX)
    assert connection.indexes(:transfers).find { |index| index.name == INDEX }.unique
  end

  test "a rerun rebuilds a leftover replacement that is not valid" do
    connection.rename_index :transfers, INDEX, TEMP_INDEX
    connection.execute(<<~SQL.squish)
      UPDATE pg_index SET indisvalid = FALSE WHERE indexrelid = to_regclass('#{TEMP_INDEX}')
    SQL
    invalid_oid = index_oid(TEMP_INDEX)

    @migration.send(:replace_index, :inflow_transaction_id, unique: true)

    assert_not_equal invalid_oid, index_oid(INDEX)
    assert_not connection.index_name_exists?(:transfers, TEMP_INDEX)
    assert connection.select_value("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass('#{INDEX}')")
  end

  private
    def connection
      ActiveRecord::Base.connection
    end

    def index_oid(name)
      connection.select_value("SELECT to_regclass(#{connection.quote(name)})::oid")
    end
end
