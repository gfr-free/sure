## Problem

The holdings list of an investment account renders, for every unlocked holding, a complete cost basis form (two money fields with their currency data, labels, buttons, confirmation data) inside a popover that is rarely opened. With 40 holdings that is 80 money fields on every load of the holdings tab.

## Change

- The popover panel now holds a `turbo-frame` with `loading: :lazy` and `refresh: :morph`. Turbo fetches it only when the panel becomes visible, i.e. when the popover opens. `refresh: :morph` keeps a loaded editor from being reset by a morph page refresh.
- New action `GET /holdings/:id/cost_basis_editor` renders the existing `holdings/_cost_basis_form` (context `:popover`) in that frame. It uses the same `set_holding` as `show` (family + accessible accounts); writes still go through `PATCH update` with its write-permission check.
- In the popover context the per-share field has `autofocus`, so focus still lands in the editor after the frame loads. The drawer editor is unchanged.
- Placeholder while loading: the shared `entries/loading` partial.

This uses a plain lazy Turbo Frame inside the existing popover, so it does not depend on #4475.

## Measured

Development mode, demo data plus 40 holdings on one account; warm, median of 7, holdings frame (`/holdings?account_id=…`):

| | before | after |
|---|---|---|
| response time | 352 ms | 222 ms (−37 %) |
| `holdings/_holding` render time (40 rows) | 191 ms | 55 ms (−71 %) |
| HTML elements | 5905 | 4185 |
| partial renders | 314 | 194 |

Opening a popover costs one small request for that holding's editor.

## Effects elsewhere

- No change to cost basis values, balances, syncs or reports. No migration.
- The drawer (holding detail) editor is unchanged.
- Known limitation, same as the lazy dropdowns: if the editor request fails (e.g. a sync removed the holding after the list rendered), the popover keeps showing the loading text until the page is reloaded.

## Tests

- The list contains the lazy frame and no cost basis form; the editor endpoint renders the form with the popover field ids and autofocus; the drawer editor has no autofocus; another family's holding returns 404.
- Full suite, system tests, RuboCop, erb_lint and Brakeman pass. No JS changes.
- No screenshots: the popover looks the same once loaded.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
