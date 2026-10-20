## Summary

Before: when a bank sync excluded a pending transaction on its own (pending for more than 8 days, or its posted version arrived as a separate row), nothing recorded it. The drawer showed the Exclude toggle switched on, exactly like a manual exclusion, and neither the user nor support could tell why or when it happened. Turning Exclude off did not stick either: the next SimpleFIN sync excluded the stale pending again.

After: each automatic exclusion is recorded, and the drawer explains it under the Exclude toggle, e.g. "On October 5, 2026 the bank sync excluded this pending transaction because it had not posted within 8 days." Turning Exclude off ends the explanation, and the stale-pending cleanup now leaves that transaction alone, the same way the Exclude rule action already respects a user's choice.

## Screenshots

| Case | Before (main) | After (this branch) |
|---|---|---|
| Pending not posted within 8 days | ![before](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sync-exclusion-note/before/1-stale-pending.png) | ![after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sync-exclusion-note/after/1-stale-pending.png) |
| Posted version arrived separately | ![before](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sync-exclusion-note/before/2-posted-match.png) | ![after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sync-exclusion-note/after/2-posted-match.png) |

Demo data from the test fixtures.

## How

- The record reuses `Enrichable`/`DataEnrichment`, which already logs who set an attribute and why (the Exclude rule action writes there with source `rule`). A new source `sync` holds one row per entry on `excluded`, with `metadata` `{ reason: "stale_pending" | "posted_match", provider: <entry source>, days | matched_entry_id }`; `updated_at` is the time of the exclusion. No migration: the table, its unique index and the string-backed enum already exist.
- `Entry.auto_exclude_stale_pending` selects and locks the stale entries (`FOR UPDATE OF entries`), upserts their records in one statement and excludes them. It never writes `transactions`, so it cannot deadlock with a normal transaction save. It skips entries whose `excluded` the user locked (new scope `Entry.excludable_stale_pending`, which also treats a NULL `locked_attributes` as unlocked, used as well by the SimpleFIN stale-pending card and the importer's "needs review" count so all three agree).
- `Entry.reconcile_pending_duplicates` calls the new `Entry#exclude_automatically!`, which re-checks the entry under a row lock, records the reason and excludes it. It returns false (and the match is not counted) when the entry was excluded or deleted meanwhile; a validation error still raises and rolls the record back. A posted duplicate still excludes the pending even if the user locked `excluded`, because both rows would otherwise count.
- An `after_save` callback deletes the record when the entry is included again, so a later manual or rule exclusion is never credited to the sync. The update action removes the explanation from the open drawer when Exclude is toggled.
- `TransactionsHelper#auto_exclusion_description` builds the sentence (`DS::Note`, en + de strings).

## Overlap with #4215

#4215 (ambiguous pending claims) adds its own narrow marker, `auto_excluded_stale_pending` in `transactions.extra`, so that Enable Banking can re-activate a stale-excluded pending when its booking arrives under the same id. Both PRs change `Entry.auto_exclude_stale_pending`. Whichever lands second will merge main and switch that marker to this record (`auto_exclusion&.metadata["reason"] == "stale_pending"`), so there is only one way to tell an automatic exclusion apart. That re-activation also covers the remaining gap here: today a stale-excluded pending that later posts stays excluded (unchanged behavior), and the drawer then explains the original exclusion.

## Impact

- Balances, reports, budgets: unchanged, the same rows are excluded as before. Exception: a stale pending the user turned Exclude off for stays included on later syncs instead of being excluded again.
- Syncs: one extra upsert into `data_enrichments` per account with stale pendings, and per reconciled duplicate.
- Rules and the "Additional details" dump: unaffected (`transactions.extra` is not touched).
- No migration, no API change, no new setting.

## Testing

- New tests: records for stale and posted-match exclusions (reason, provider, days, matched entry, time, refresh on repeat), dry run records nothing, manual exclusion records nothing, user lock respected by the stale cleanup, the card count and the review count, posted duplicate still excluded under a lock, entry excluded or deleted meanwhile, validation error rolls back, inclusion deletes the record and a later rule exclusion is not attributed to the sync, entry with NULL `locked_attributes` still cleaned up, drawer shows the explanation and removes it on toggle without locking `extra`, helper sentence per reason.
- `bin/rails test`: full suite green locally (12455 runs before the last small fix, affected files re-run after it); CI green.
- `bin/rubocop`, `erb_lint`, `bin/brakeman`: clean. No JavaScript changes.
