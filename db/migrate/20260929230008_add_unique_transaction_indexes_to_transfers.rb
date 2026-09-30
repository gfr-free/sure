class AddUniqueTransactionIndexesToTransfers < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # A transaction may belong to at most one transfer, on either side. Until now
  # only the (inflow, outflow) pair was unique in the database; per-column
  # uniqueness was a check-then-insert validation, so concurrent syncs running
  # Family#auto_match_transfers! could put one transaction into two transfers.
  #
  # Existing duplicates are resolved first, or the unique indexes cannot be
  # built. Per conflicting group the kept transfer is chosen deterministically:
  # confirmed before pending, then one with fee transactions, then the oldest
  # (created_at, then id). Every other transfer that shares a transaction with
  # an already kept one is deleted. For each deleted transfer:
  #   - its fee transactions (normally none on auto-matched transfers) are kept
  #     as standalone transactions: transactions.transfer_id is set to NULL;
  #   - each of its inflow/outflow transactions that is no longer part of any
  #     remaining transfer (on either side) is reset the way Transfer#destroy! resets it: kind becomes
  #     "standard" and the entry's idempotency_key is cleared;
  #   - the transaction it shares with the kept transfer is left untouched.
  # Deleted pairs are not recorded as rejected, so the next sync may match a
  # freed transaction again, now protected by these indexes.
  def up
    replace_index :inflow_transaction_id, unique: true
    replace_index :outflow_transaction_id, unique: true
  end

  # The indexes are restored as non-unique; deleted duplicate transfers are not.
  def down
    replace_index :inflow_transaction_id, unique: false
    replace_index :outflow_transaction_id, unique: false
  end

  private
    # Builds the replacement index under a temporary name before touching the
    # existing one, so the column is never left without a valid index: if a
    # concurrent sync inserts a duplicate and the unique build fails, only the
    # temporary index is INVALID and the old index keeps serving queries. A re-run
    # drops that leftover and tries again. Duplicates are resolved immediately
    # before each unique build to keep that window as small as possible.
    def replace_index(column, unique:)
      name = "index_transfers_on_#{column}"
      temp_name = "#{name}_new"

      resolve_duplicate_transfers if unique

      remove_index :transfers, name: temp_name, if_exists: true, algorithm: :concurrently
      add_index :transfers, column, name: temp_name, unique: unique, algorithm: :concurrently
      remove_index :transfers, name: name, if_exists: true, algorithm: :concurrently
      rename_index :transfers, temp_name, name
    end

    def resolve_duplicate_transfers
      rows = select_rows(<<~SQL.squish)
        SELECT t.id, t.inflow_transaction_id, t.outflow_transaction_id
        FROM transfers t
        WHERE t.inflow_transaction_id IN (
            SELECT inflow_transaction_id FROM transfers GROUP BY inflow_transaction_id HAVING COUNT(*) > 1
          )
          OR t.outflow_transaction_id IN (
            SELECT outflow_transaction_id FROM transfers GROUP BY outflow_transaction_id HAVING COUNT(*) > 1
          )
        ORDER BY
          (t.status = 'confirmed') DESC,
          EXISTS (SELECT 1 FROM transactions f WHERE f.transfer_id = t.id) DESC,
          t.created_at ASC,
          t.id ASC
      SQL
      return if rows.empty?

      claimed = Set.new
      losers = []
      rows.each do |id, inflow_id, outflow_id|
        if claimed.include?(inflow_id) || claimed.include?(outflow_id)
          losers << [ id, inflow_id, outflow_id ]
        else
          claimed << inflow_id << outflow_id
        end
      end

      loser_ids = losers.map(&:first)
      freed_ids = losers.flat_map { |_, inflow_id, outflow_id| [ inflow_id, outflow_id ] }.uniq - claimed.to_a

      say "Removing #{loser_ids.size} duplicate transfer(s); resetting #{freed_ids.size} unlinked transaction(s) to standard"

      transaction do
        execute(<<~SQL.squish)
          UPDATE transactions SET transfer_id = NULL, updated_at = NOW()
          WHERE transfer_id IN (#{quoted_list(loser_ids)})
        SQL

        execute("DELETE FROM transfers WHERE id IN (#{quoted_list(loser_ids)})")

        if freed_ids.any?
          # A freed id can still be the other-side endpoint of a surviving
          # transfer outside the conflicting groups (inflow here, outflow
          # there); only reset transactions no remaining transfer references.
          unreferenced = <<~SQL.squish
            NOT EXISTS (
              SELECT 1 FROM transfers r
              WHERE r.inflow_transaction_id = transactions.id OR r.outflow_transaction_id = transactions.id
            )
          SQL

          execute(<<~SQL.squish)
            UPDATE transactions SET kind = 'standard', updated_at = NOW()
            WHERE id IN (#{quoted_list(freed_ids)}) AND #{unreferenced}
          SQL

          execute(<<~SQL.squish)
            UPDATE entries SET idempotency_key = NULL, updated_at = NOW()
            FROM transactions
            WHERE entries.entryable_type = 'Transaction'
              AND entries.entryable_id = transactions.id
              AND transactions.id IN (#{quoted_list(freed_ids)})
              AND entries.idempotency_key IS NOT NULL
              AND #{unreferenced}
          SQL
        end
      end
    end

    def quoted_list(ids)
      ids.map { |id| connection.quote(id) }.join(", ")
    end
end
