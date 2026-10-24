Related to #119 and #195.

## Problem

`DestroyJob` rescues every error from `model.destroy` so the job ends instead of retrying, and then drops the error: nothing in `/settings/debug`, the Rails log or Sentry. Since #4173 an account whose destroy fails returns to `disabled` and provider items get `scheduled_for_deletion` reset, but nobody can tell **why** the deletion failed, which is what #119 and #195 could never pin down.

Related bugs in the same rescue:

- The reset used `update!`, which re-runs validations. `QuestradeItem` only requires `refresh_token` while the flag is **not** set, so the reset raised `RecordInvalid` out of the rescue, the job went into Sidekiq retries and the connection showed "Deletion in progress" forever. `DestroyableLater#restore_scheduled_for_deletion` already uses `update_column` for this reason.
- The broad `rescue` also caught `ActiveRecord::Deadlocked`, so `retry_on Deadlocked` from `ApplicationJob` never applied. A deletion that deadlocked with a concurrent sync had to be restarted by hand.
- A destroy aborted by a callback returns `false` without raising, so it was neither logged nor reset.

## Behaviour after

- A failed destroy writes one `DebugLogEntry` (category `background_jobs`, level `error`, source `DestroyJob`), plus `Rails.logger.error` and `Sentry.capture_exception`.
  - Account: linked via `account:`. Family: linked to itself. Provider items: linked to their family, with `provider_key` (e.g. `plaid`).
  - Metadata: `record_type`, `record_id`, `error_class`, `error_message` (truncated to 500 chars), `record_errors` (why a callback aborted the destroy), first 5 backtrace lines.
  - If the record is already gone (error raised in an after-commit step), only the family is linked, so the `debug_log_entries` foreign keys cannot reject the row, and `Account#destroy` no longer tries to restore the frozen record (which used to replace the real error with a `FrozenError`).
- A deadlock is retried (5 attempts, `polynomially_longer`: about 3 s, 18 s, 83 s, 258 s) without logging or resetting. An account stays `pending_deletion` while it is retried, so a user cannot re-enable it and then lose it to the retry. Only when the attempts run out is it handled like any other failure (account back to `disabled`).
- A `false` result from `destroy` raises `ActiveRecord::RecordNotDestroyed` and is handled like any other failure; an account is restored to `disabled`.
- The `scheduled_for_deletion` reset uses `update_column` and is skipped for a destroyed record. If the database still rejects it (the partial unique index on `trade_republic_items` is gated by the flag), the error is logged instead of sending the job into Sidekiq retries.
- A successful destroy writes nothing. Account recovery from #4173 is otherwise unchanged.

## Investigation (#195)

On current main no foreign-key failure could be reproduced: a loan with a loan-payment transfer from checking, the same with source and destination fees, a split transaction and every fixture account (goals, pledges, shares, holdings, statements) all delete cleanly. So no migration; the new logging will show the real cause if it still happens. Accounts stuck in `pending_deletion` from before #4173 are not migrated.

## Tests

`test/jobs/destroy_job_test.rb`: account failure logged with account/family and metadata; provider item logged with family and `provider_key`; family failure; record without family; Rails log + Sentry; QuestradeItem flag reset without validations; successful destroy logs nothing; aborted destroy logged and flag reset; aborted account destroy logged with its reason and left disabled; deadlock enqueues a retry without logging; account stays `pending_deletion` during a deadlock retry; deadlock outlasting retries logged, flag reset / account disabled; account deleted on retry after one deadlock; error after the delete committed logged as itself; reset rejected by the database does not raise. The new behaviour tests fail without the change.

## Validation

- `bin/rails test`: 13173 runs, 0 failures, 0 errors, 36 skips
- `bin/rubocop` on changed files: no offenses
- `bin/brakeman`: no warnings
- ERB lint, Biome, system tests: not applicable (no UI or JS change)

No screenshots: no UI change.
