# Replies for upstream PR 4469 (one per bot thread, then resolve)

## Codex P1, app/jobs/destroy_job.rb (deadlock after the delete committed)
Good catch, fixed in 367fde2: a `Deadlocked` raised after the row is gone (`model.destroyed?`) is now reported right away through `handle_failure` instead of being retried into a discarded `DeserializationError`. Covered by "a deadlock after the account delete committed is recorded instead of retried".

## Codex P1, app/jobs/destroy_job.rb (failed restore only in the Rails log)
Fixed in 367fde2: a restore the database rejects now goes through `report_failure`, so it gets its own `DebugLogEntry` (plus Rails log and Sentry) next to the original error. The test now asserts both entries.

## CodeRabbit, app/jobs/destroy_job.rb (restore in ensure)
Done in 367fde2: `restore` runs in an `ensure`, so a failing log write can no longer skip it. Covered by "the flag is reset even when recording the failure raises".
