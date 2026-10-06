@jjmata thanks a lot for testing this so thoroughly in a real browser, that caught things the existing tests didn't. All three points are addressed in a7654e5:

1. **Fixed split summary after condition edits.** The rule builder's split summary now also listens to input/change events on the whole rule form and observes the conditions list (rows added, removed, or re-rendered after an operator switch). With 70 + 30 and Amount = 100 it reads green `100.00 / 100.00`; changing Amount to 120 switches it to red `100.00 / 120.00` right away. New system test: `RulesTest#test_fixed_split_summary_follows_edits_to_the_exact_amount_condition` (fails without the fix).

2. **Malformed rows and non-finite shares.** `config_errors` now rejects any non-object row (`null`, strings, numbers) as an invalid configuration instead of raising, so `{"splits":[null,null]}` is a validation error rather than a 500. `parse_config` also ignores such stored values, so execution and `value_display` can't trip over them. `NaN`, `Infinity` and `-Infinity` are now treated as unparseable decimals, so they fail the "share must be a positive number" check at save time. Regression tests cover null/string/number rows and all three non-finite values, plus an executor test that a stored config with null rows is a no-op.

3. **Manual split metadata row overflow.** The category/merchant/tag row now uses three equal grid columns (`md:grid-cols-3`, `min-w-0` pickers) instead of fixed-width flex items, so it always shares the row's width. New system test `SplitsTest` checks that no split row in the edit dialog overflows at the default 1400px viewport (it measured an overflow before the change).

Before / after of the edit dialog at 1400px (the tag picker's right edge was clipped):

![Split row layout before and after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/split-transaction-rule/row-layout-before-after.png)

Locally: full `bin/rails test` green (10639 runs, 0 failures, 0 errors), the new and existing rule system tests green, plus rubocop, erb_lint, Biome lint and Brakeman clean.

@coderabbitai full review
