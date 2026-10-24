## Problem

On linked (reverse-synced) investment accounts, `Holding::Materializer` can persist historical holdings with negative `qty`/`amount` via `upsert_all`, for example when manual trades duplicate provider-synced trades. `Holding#remap_security!` and `#reset_security_to_provider!` then re-saved every row with validations, so the first negative row raised `RecordInvalid` and the whole remap was rolled back. The controller didn't rescue: the user got a 500 with no message, and the target security (shared across families) had already been saved with the new `price_provider` / online state.

## Changes

- **`Holding#remap_security!`**
  - Holdings that don't collide are moved with one set-based `update_all` (`provider_security_id = COALESCE(provider_security_id, old_id)`, `security_id`, `security_locked`), the same way trades are already moved and the way the materializer wrote the rows.
  - Only colliding rows (same date and currency on the target security) are loaded; the targets are loaded once instead of one `find_by!` per row.
  - Colliding rows are merged with `update_columns`. The source row is destroyed first, because its `external_id` may be carried over and `(account_id, external_id)` is unique.
  - The merge keeps the target's price and cost basis unless both rows hold shares, so a negative reconstructed row never yields a negative stored price or cost basis.
- **`Holding#reset_security_to_provider!`**: same set-based `update_all` instead of `update!` per row.
- **`HoldingsController#remap_security`**: `new_security.save!` and `remap_security!` run in one transaction, so a failed remap no longer changes a shared security. `RecordInvalid`/`RecordNotUnique` show a flash alert instead of a 500.
- **`HoldingsController#reset_security`**: `RecordNotUnique` shows a flash alert.
- Both failures are recorded with `DebugLogEntry.capture` (category `holdings`, account context) so support can inspect them.
- New `error` strings for `holdings.remap_security` / `holdings.reset_security` (en, de).

A remap on a long history is now a few `UPDATE` statements instead of one save per day.

## Behavior

- Remapping or resetting a holding whose history contains negative reconstructed quantities works, and the rows keep their values.
- If a remap/reset still fails, the user sees "Could not update/reset the security…", nothing is changed (including the shared security), and a debug log entry is written.

## Validation

- Model tests: remap moves negative rows; an existing `provider_security_id` is kept; a negative row merges into a colliding holding; merging never stores a negative price or cost basis; the provider `external_id` is carried over on merge; reset restores negative rows. The two merge-price tests fail on the previous code.
- Controller tests: a failed remap shows an alert, writes a debug log entry and leaves the shared security offline/untouched; a failed reset shows an alert and writes a debug log entry.
- Full `bin/rails test`: 13165 runs, 0 failures, 0 errors, 36 skips.
- `bin/rubocop` on changed files: no offenses. `bin/brakeman`: 0 warnings. No ERB/JS changes (erb_lint/Biome not applicable). No UI change besides the flash alert, so no screenshots.

### Known limitation (unchanged by this PR)

`reset_security_to_provider!` still has no collision handling: if the original security already has a row on the same date and currency (for example after a later sync rebuilt it), the reset fails. Before this PR that was a 500; now it is an alert plus a debug log entry. Merging on reset is left for a follow-up.
