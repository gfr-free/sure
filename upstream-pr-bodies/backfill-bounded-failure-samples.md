Follow-up to #4936, covering three review points that landed after it was merged.

## Problem

- `security:backfill_encryption` kept every failing row in memory, although the report shows only three per table. A dry run against a large table whose rows use other keys (the check the docs ask for before switching to your own keys) grew with the table and could run out of memory before printing its report.
- The tests checked the JSON report but not the exit status, which the Docker guide relies on.
- The previews in the Docker guide ran the task without a dry-run argument, so it read `DRY_RUN` from the container environment. With `DRY_RUN=false` set there, the preview wrote. If rows then failed and the operator removed the new keys as the guide says, rows the preview had already converted became unreadable.

## Changes

- The task counts every failure but keeps at most three samples per table.
- `run_backfill` in the test keeps the exit status. The tests assert status 1 for a dry run and a real run with refused rows, and status 0 for a clean run.
- A new test refuses five rows and checks `failed_count` 5 with three samples.
- Both previews in `docs/hosting/docker.md` pass `1` as the dry-run argument, which takes precedence over the environment, and the steps ask to check for `"dry_run":true` in the report.

## Tests

`test/lib/tasks/security_backfill_test.rb` and the encryption tests pass with keys; Rubocop is clean.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
