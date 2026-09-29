class AddEntryableLookupIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # `has_one :entry, as: :entryable` looks entries up by
    # (entryable_type, entryable_id). Without this index every
    # `transaction.entry`, entry preload and `touch: true` scans all entries
    # of that type. The composite index also covers the old single-column one.
    add_index :entries, [ :entryable_type, :entryable_id ],
      name: "index_entries_on_entryable",
      algorithm: :concurrently,
      if_not_exists: true
    remove_index :entries, :entryable_type,
      name: "index_entries_on_entryable_type",
      algorithm: :concurrently,
      if_exists: true

    # IncomeStatement#cache_freshness_key reads ExchangeRate.maximum(:updated_at)
    # on every dashboard, report and budget render.
    add_index :exchange_rates, :updated_at,
      algorithm: :concurrently,
      if_not_exists: true
  end
end
