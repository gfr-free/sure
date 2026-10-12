class RemoveRedundantEntriesEntryableTypeIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # The composite (entryable_type, entryable_id) index from the previous
  # migration covers lookups by entryable_type alone.
  def change
    remove_index :entries, :entryable_type,
      name: "index_entries_on_entryable_type",
      algorithm: :concurrently
  end
end
