## Problem

Most edit paths saved a user's change first and wrote the attribute locks (`lock_saved_attributes!`) and the `user_modified` flag in later, separate commits. That affected the web controllers for transactions, trades and categories, API v1 and the assistant functions. A provider sync or a rule running in that window saw the change without its lock and could overwrite it (name, category, excluded, amount and so on).

Making the edit atomic is not enough on its own. Syncs and rules checked the locks on a copy loaded earlier, so a sync that read the row before the edit committed still overwrote it afterwards. The two-connection race test below shows this: with only the writer side fixed, it still fails.

This came up in review on #4340 (the inclusion flag and its lock were not saved together); it is fixed here for all edit paths instead.

## Change

**Writer side**
- `Enrichable#save_and_lock_attributes { save }` runs the save and the locks in one transaction (a savepoint when nested). When the block returns false, everything the block wrote is rolled back.
- `Entry#save_and_lock_attributes(user_modified:, lock_tags: :if_any | :always)` also writes the tag lock and the user-modified flag in the same transaction.
- These paths now use it: `TransactionsController#create/update/update_tags`, `TradesController#update`, `TransactionCategoriesController#update`, API `transactions#create`, API `trades#create/update`, `Assistant::Function::CreateTransaction` and `Trade::CreateForm`. `TradesController#create` and API `trades#create` drop their own lock and flag calls.
- Paths that already ran in one transaction keep their shape: `AccountableResource` create/update, `convert_to_trade`, `TransfersController#update_tags`, API `transactions#update`, `Entry.bulk_update!` and `Assistant::Function::UpdateTransaction`.

**Reader side**
- `Enrichable#enrich_attributes` re-reads `locked_attributes` with `FOR UPDATE` before it writes. This covers rules, AI categorisation, merchant detection and provider name/category/merchant/notes. Nothing is locked when nothing would change.
- `ProviderImportAdapter#import_transaction` locks and re-checks an entry that looked unprotected before overwriting it (`Entry#lock_with_entryable!`), both for the `external_id` match and for a claimed manual duplicate. A stale "protected" reading only defers the import to the next sync. An entry the user deleted meanwhile is left alone.

**Lock order and fresh locks**
- Saves write `transactions` before `entries` (`has_one :entry, touch: true`). `Entry#reload_locked_attributes_for_update` takes the entryable row first and the entry row second and refreshes the locks of both. The edit helper, the API and assistant updates, bulk edit and the Entry side of `enrich_attributes` all go through it, so an edit cannot deadlock with a sync or rule, and `lock_attr!` merges into the committed locks rather than those loaded at request start.
- `Financekit::Processor` and `Transaction#merge_with_duplicate!` locked the entry before its transaction. They now use `lock_with_entryable!`, the same order (`with_split_lock` already uses it).

**Related bug fixed:** bulk edit, the API update and the assistant update called `lock_saved_attributes!` after saving tags. That save replaced the saved changes, so a category edited together with tags was never locked. These paths now lock first.

## Effects

- **Provider syncs (`import_transaction`):** one extra `SELECT … FOR UPDATE` on two rows per existing, unprotected entry. A sync now waits for a user edit still in progress instead of overwriting it. In importers that wrap a whole batch in one transaction, an edit of a row in that batch waits until the batch commits. Balances and reports are unchanged.
- **Rules and AI categorisation:** one extra locked `SELECT` per record that would actually change.
- **Trades created from the form or API:** unchanged behaviour; still user-modified and locked, now inside `Trade::CreateForm`.
- **Account syncs** (`sync_account_later`) are still enqueued after the edit commits.

## Tests

- New `test/models/entry/save_and_lock_concurrency_test.rb` with two real connections and `pg_blocking_pids`:
  - provider sync versus an edit in progress, and rule versus an edit in progress. Both fail without the reader side;
  - an entry-only edit with a tag lock versus a rule. Without the lock order it fails with `PG::TRDeadlockDetected`.
- Rollback tests (failed block, failing lock, failing `mark_user_modified!`, rollback inside an outer transaction) and a controller test.
- A lock committed after the entry was loaded is kept.
- A manual duplicate the user protected during an import is linked but not overwritten.
- Order tests for bulk, API and assistant (category plus tags), which fail on `main`.
- New `test/controllers/api/v1/trades_controller_test.rb` cases for the trade API paths.

## Validation

- `bin/rails test`: 13174 runs, 0 failures, 0 errors
- Rubocop: no offenses. Brakeman: no warnings. No ERB or JavaScript changes, so no screenshots.

## Not changed here (pre-existing)

- `notes_changed` in `TransactionsController#update` is read after the lock saves and is therefore always false, so the notes frame is never replaced.
- Removing all tags locks `tag_ids` only in `update_tags` (`lock_tags: :always`); the other paths lock tags only when some remain.
- The import's skip branch writes `extra` from the unlocked copy.
- `import_trade` does not check locks.
