## Problem

`SplitsTest#test_edit_dialog_saves_the_merchant_and_tags_picked_with_the_DS_pickers` fails intermittently in CI:

```
--- expected
+++ actual
-"<merchant id>"
+nil
```

The split editor (`SplitsController#edit`) and the split list in the transaction drawer (`transactions/show.html.erb`) read `@entry.child_entries` without an `ORDER BY`. PostgreSQL then returns the rows in physical order. That order shifts once a row is rewritten and the planner picks a sequential scan, which depends on what earlier tests left in the table. The test picks the first row in the dialog and expects "Groceries". When "Household" comes first, it gets the merchant instead and "Groceries" keeps `nil`.

The same thing affects users: the rows of a split can appear in a different order than they were entered, in the edit dialog and in the drawer.

**Reproduced:** a throwaway system test that rewrites the "Groceries" row once (`update_all("name = name")`) made the dialog list "Household" first and failed with exactly the CI message. With this change it passes.

## Change

- New scope `Entry.in_split_order`, which is `order(:created_at, :id)`, the same order the data export already used.
- Used in `SplitsController#edit`, in the drawer's split list and in `Family::DataExporter#split_child_entries_for_export`. The export result is unchanged.
- Controller tests for the edit dialog and the drawer check that the rows render in entry order and that every read of the split rows carries the `ORDER BY`. Both fail without the fix. They don't rely on heap layout, so they are deterministic.

## Behaviour

- Only the display order of split rows changes. Balances, rules, the API and the export output stay the same.
- The ordering lives in an explicit scope rather than on the `has_many`. Existing callers chain their own `order(...)`, and an association-level order would take precedence over it.

## Validation

- Full `bin/rails test` is green.
- System tests `test/system/splits_test.rb` and `test/system/transactions_test.rb` are green.
- `bin/rubocop`, `erb_lint` and `bin/brakeman` are green. There are no JS changes.
- No screenshots: the layout is unchanged, and the only visible effect is a stable row order.
