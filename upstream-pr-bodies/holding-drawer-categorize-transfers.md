## Problem

We measured every GET UI route against the full demo dataset (8,473 entries, 370 trades, 451 pending auto-matches) in production mode with the Redis cache, warm, median of 5–9 requests. Four pages stood out because of avoidable work that grows with the data:

1. **Holding drawer (`/holdings/:id`)**: 580 ms, 129 queries. The trade history called `@holding.trades.length` inside its loop. `Holding#trades` builds a new relation on every call, so each row reloaded all trade entries (O(n²)). Each row also loaded its `Trade` separately (N+1).
2. **Quick Categorize (`/transactions/categorize`)**: 275 ms. About 34 % of the request was spent in `Entry#generic_name?`, which ran one I18n lookup per supported locale for every entry. `Category#any_locale_display_name_matches?` did the same for default category names.
3. **Auto-match list (`/auto_matches`)**: 136 ms, about 75 ms of it SQL. Every transfers query (exists check, pagination count, page load) ran two `IN (SELECT DISTINCT transactions.id …)` subqueries, each joining all family transactions to accounts and account shares.
4. **Transfer drawer (`/transfers/:id`, also used by confirm/reject)**: `set_transfer` built the same subquery.

## Change

- `HoldingsController#show` loads the trade entries once, with `includes(:entryable)`. The view reuses that array for the earliest-date check, `any?`, the loop and the last-row check. The ticker comes from `@holding`, because every trade of a holding shares its security.
- New `LanguagesHelper.folded_translations(key)` returns a per-process, frozen set of every supported locale's translation of a key, case-folded. `Entry#generic_name?` and `Category#any_locale_display_name_matches?` use it. `downcase(:fold)` plus a set lookup behaves like the previous `casecmp?`, which also uses Unicode case folding.
- `AutoMatchesController` and `TransfersController#set_transfer` look up the user's accessible account ids once via `Current.user.accessible_accounts.ids` (same family and owner/share scope as before). Each transfer leg then filters on `entries.account_id`, with no join and no DISTINCT.

## Measured (production mode, demo data, warm, median)

| Page | Before | After | Queries / SQL |
|---|---|---|---|
| Holding drawer (111 trades) | 574–590 ms | 150–170 ms | 129 → 19 queries |
| Quick Categorize | 260–291 ms | 160–162 ms | unchanged (15) |
| Auto-match list (451 pending) | 136 ms | 71–79 ms | SQL 70–75 → 17–22 ms |
| Transfer drawer | 116–144 ms | 133–140 ms (noise) | SQL 27–30 → 11–12 ms |

## Effects elsewhere

- Read paths only: no effect on balances, reports, syncs or jobs.
- Name grouping in Quick Categorize and the recurring smart-fill evidence (both use `generic_name?`) give the same results as before.
- Access rules for auto-matches and transfers are unchanged. Existing tests cover private accounts, read-only shares and 404s; a new test covers matches between accounts shared with a member.
- Locale files are read once per process for the two name checks; locales only change on deploy.

## Tests

- The holding drawer loads trades with exactly one query (fails on main).
- `generic_name?` ignores case and surrounding spaces.
- The auto-match list shows matches between accounts shared with a member.
- Full suite, RuboCop, erb_lint and Brakeman pass. No JS changes.
- No screenshots: same markup, rendered faster.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
