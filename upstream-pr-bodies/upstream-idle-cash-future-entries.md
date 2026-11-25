## Problem

The idle cash insight (`IdleCashGenerator`) treats an account as active when it has any entry dated within the last 60 days, with no upper bound. A scheduled entry dated in the future therefore counts as recent activity, and an account untouched for months is not reported as idle while a planned booking sits on it.

## Change

One line: the activity subquery uses `Entry.excluding_scheduled` (`date <= today`), the same cutoff used elsewhere for "real" entries.

## Resulting behavior

Only the idle cash card changes: it can now appear for accounts whose only entry in the window is dated in the future. Nothing else is affected.

## Validation

- Two new tests in `test/models/insight/generators/idle_cash_generator_test.rb`: a future-dated entry does not count as activity (fails on main, passes here), and an entry 10 days ago still does (passes on both).
- `bin/rails test test/models/insight` on current main: 189 runs, 0 failures. Full CI green on the branch.
- Rubocop clean. No view or JS changes, so no screenshots.
