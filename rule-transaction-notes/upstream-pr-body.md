## Summary

Before: rules can match on transaction notes but cannot write them. Notes such as "Check receipt" or "Reimbursable" have to be added by hand on every transaction.

After: two new transaction rule actions.
- **Set transaction notes** replaces the notes with the given text.
- **Add line to transaction notes** adds the text as a new line, but only when no line of the notes already equals it. Rules run again after every sync, so without that check the notes would grow on every run.

Release notes: Rules can now set transaction notes or add a line to them.

## How

- `Rule::ActionExecutor::SetTransactionNotes` and `AppendTransactionNotes` are `type "text"`, like *Set transaction name*. Both write `entries.notes` through `entry.enrich_attribute(:notes, ..., source: "rule")`.
- Locked notes (edited by hand) are skipped in automatic runs and only overwritten on an explicit apply with `ignore_attribute_locks`, the same as the name action.
- Rule order ("top rule wins") is kept, with appends adding up like tags:
  - New executor hook `blocking_attributes` (default: `claimed_attributes`) names the claims that keep an action away from a transaction. `Rule#apply` now excludes by `blocking_attributes`; every existing action keeps its behavior because the default is unchanged.
  - *Set* claims `notes` and is blocked by `notes` and `appended_notes`.
  - *Append* claims `appended_notes` and is blocked only by `notes`.
  - Result: several append rules each add their line, a set rule above wins over appends below, and an appended line is never wiped by a set rule further down.
- The duplicate check compares whole lines after trimming, so "Reimbursable" is still added to a note that reads "Reimbursable by employer". A value with several lines (possible through the API, rule import or the assistant) is checked line by line and only the missing lines are added, so repeated runs converge.
- Blank values do nothing and claim nothing, so a blank note action never keeps note rules below it away.
- One rule cannot hold both note actions (validation `conflicting_note_actions`): replace and append in the same rule would rewrite the notes on every run. Two separate rules work as described above.
- Labels use `t()` (en, de; other locales fall back to en). The `conflicting_note_actions` error is translated in every locale that has `duplicate_actions`.
- `get_rule_options` describes the expected value of both actions for the assistant.

## Scope and permissions

Only `entries.notes` changes; balances, reports, budgets and syncs are not affected. Each change writes a `data_enrichments` row with source `rule`, like the other rule actions. Action types are free strings, so rule export/import and the read-only rules API carry the new types without changes. No migrations.

Rules stay family-wide and non-guest only, the same as the existing name, category and merchant actions; this PR does not change who may create rules.

## Coordination with other rule PRs

- Built on the action type validation from #4175: both executors are entries in `ACTION_EXECUTOR_CLASSES`.
- #4176 adds tests at the end of `test/models/rule/action_test.rb`, as this PR does. Whichever lands second keeps both; no code overlap.

## Screenshots (demo data)

| Before | After |
|---|---|
| ![before](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-transaction-notes/before-action-select.png) | ![after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-transaction-notes/after-action-select.png) |

A transaction after an append rule ran (existing note "Paid by card" plus the appended line):

![transaction notes](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-transaction-notes/after-transaction-notes.png)

## Testing

- `test/models/rule/action_test.rb`: set, append, duplicate check, whole-line matching, multi-line values, blank values, locks and lock override.
- `test/models/rule/runner_test.rb`: a blank set or append action above leaves the notes to the rule below.
- `test/models/rule/runner_test.rb`: set above beats append, append above keeps set below away, two appends add up and stay stable across repeated runs.
- `test/models/rule_test.rb`: a rule with both note actions is rejected.
- `test/models/assistant/function/get_rule_options_test.rb`: value description for the append action.
- Full `bin/rails test` on current main: 12,448 runs, 0 failures, 0 errors.
- rubocop, erb_lint, biome, brakeman clean.
