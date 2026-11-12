Follow-up to #4936, covering two review points that landed after it was merged.

## Problem

- `security:backfill_encryption` kept every failing row in memory, although the report shows only three per table. A dry run against a large table whose rows use other keys (the check the docs ask for before switching to your own keys) grew with the table and could run out of memory before printing its report.
- The tests checked the JSON report but not the exit status, which the Docker guide relies on.

## Changes

- The task counts every failure but keeps at most three samples per table.
- `run_backfill` in the test keeps the exit status. The tests assert status 1 for a dry run and a real run with refused rows, and status 0 for a clean run.
- A new test refuses five rows and checks `failed_count` 5 with three samples.

## Tests

`test/lib/tasks/security_backfill_test.rb` and the encryption tests pass with keys; Rubocop is clean.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
