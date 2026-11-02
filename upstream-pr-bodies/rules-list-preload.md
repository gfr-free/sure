## Problem

The rules settings page (`/rules`) ran about four queries per rule and rebuilt a full option list (all categories, merchants or accounts) for every condition and action it displayed, just to turn a stored id into its label. Each executor lookup also built every executor, which resolves the AI categorization provider and the LLM provider each time. With 100 rules the page took close to 3 seconds.

## Change

- `RulesController#index` preloads `actions` with the rules. The row counts them in memory (`size` instead of `count`) and reads the displayed action from the preloaded records (`Rule#displayed_action`, the same pick as `actions.first`: lowest id, saved actions only).
- `Rule::Registry::TransactionResource#get_filter!` / `#get_executor!` build only the class asked for and reuse it per registry. `offered?` checks whether the rule already has the AI action before resolving the provider. Accept/refuse decisions are unchanged.
- `Rule::Condition#options` / `Rule::Action#options` go through `Rule#option_list`, a per-rule memo. `Rule.share_option_lists(rules)` lets the rules on the list page share one memo, because the lists depend only on the family and the current user. `reload` clears it.

The preloading part overlaps with #2260, which only preloads `actions`; this PR also removes the per-row option-list and executor work, which is where most of the time went.

## Measured

Development mode with caching, demo data plus 100 rules (mixed name/merchant/amount/category conditions with an account condition, category or merchant actions) and 200 merchants; warm, median of 7:

| `/rules` | before | after |
|---|---|---|
| response time | 2890 ms | 379 ms (−87 %) |
| SQL queries | 415 | 19 |
| `rules/_rule` render time (102 rows) | 1986 ms | 117 ms |

The rendered rule rows are byte-identical before and after (only random element ids and the session differ).

## Effects elsewhere

- Rule execution (`Rule#apply`, jobs) uses the same `get_filter!`/`get_executor!`; it now builds one object per lookup instead of all of them. Results are unchanged.
- No change to balances, reports, syncs, imports or the API. No migration.
- Rule edit form: option lists are memoized per rule object within the request.
- The option cache is shared explicitly on the list page rather than request-wide on `Current`, so jobs and other callers keep their current behaviour.

## Tests

- `/rules` runs the same number of queries for 2 and 6 rules (on main: 36 vs 64).
- Registry lookups: unsupported/not-offered keys still raise, no provider check for ordinary or existing AI actions.
- `displayed_action` skips unsaved actions; `reload` clears option lists.
- Full suite, RuboCop, erb_lint and Brakeman pass. No JS changes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
