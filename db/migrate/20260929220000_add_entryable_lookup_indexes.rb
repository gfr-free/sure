class AddEntryableLookupIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # No if_not_exists: a failed concurrent build leaves an INVALID index behind,
  # and skipping it on a rerun would drop the old index with nothing usable in
  # its place. Failing loudly makes the operator drop the leftover first.
  def change
    # `has_one :entry, as: :entryable` looks entries up by
    # (entryable_type, entryable_id). Without this index every
    # `transaction.entry`, entry preload and `touch: true` scans all entries
    # of that type. The composite index also covers the old single-column one.
    add_index :entries, [ :entryable_type, :entryable_id ],
      name: "index_entries_on_entryable",
      algorithm: :concurrently
    remove_index :entries, :entryable_type,
      name: "index_entries_on_entryable_type",
      algorithm: :concurrently

    # IncomeStatement#cache_freshness_key reads ExchangeRate.maximum(:updated_at)
    # on every dashboard, report and budget render.
    add_index :exchange_rates, :updated_at, algorithm: :concurrently
  end
end
