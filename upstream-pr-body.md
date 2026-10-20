**Before:** Accounts in the sidebar and on the dashboard can only be ordered by name or balance (Settings → Preferences → Default Account Order). There is no way to put, say, the main checking account on top.

**After:** Default Account Order moves to **Settings → Appearance**, next to "Start expanded by default", and gets a new option, **Manual (drag to reorder)**. With it, a **Sort accounts** button appears next to expand/collapse in the sidebar. It turns on a sort mode: groups open, every account row shows a grip handle, and a hint bar with **Done** appears. Outside sort mode the list looks exactly as with the other orders. In sort mode a row can be dragged within its group with the mouse, moved by press-and-hold on touch, or moved with the keyboard (focus the handle, Enter, arrow keys, Enter). The order is saved per user right away and also applies to the dashboard balance sheet. Accounts added later appear after the arranged ones, alphabetically.

Addresses #3107 (suggestions 1 and 2) and discussion #2913.

## Screenshots

Demo data.

Settings → Appearance, new option:
![Settings](https://raw.githubusercontent.com/gfr-free/sure/screenshots/account-order/1-settings-manual.png?v=2)

Sidebar with manual order: sort mode off, sort mode on, and an account grabbed with the keyboard and moved up:
![Sort mode](https://raw.githubusercontent.com/gfr-free/sure/screenshots/account-order/6-sort-mode-off-on-moving.png)

## How

- `AccountOrder` gets a `manual` key. The name and balance options are unchanged, so saved preferences keep working.
- The select moves from `settings/preferences` to `settings/appearances`. `Settings::AppearancesController#update` sets `default_account_order` only for known order keys. Labels reuse the existing `settings.preferences.show.default_account_order*` keys, so existing translations still apply.
- The order lives in `users.preferences["manual_account_order"]` as `{ "depository" => [account ids…], … }`, one list per account type group. `User#update_manual_account_order` keeps only accounts the user can access (`accessible_accounts`, family-scoped) and only valid group keys, rejects non-array input, caps each list at 500 ids and writes under a row lock, like the dashboard preferences.
- New endpoint `PATCH /accounts/reorder` (`AccountsController#reorder`) with `group` and `account_ids`.
- `BalanceSheet#sorted` applies the manual order; sidebar and dashboard both read from it.
- The sidebar uses the shared `sortable_list_controller.js` (as reports and rules do) instead of its own copy. Each group list posts `{ account_ids: [...] }` to `reorder_accounts_path(group: key)`. Additions to the shared controller are opt-in values or guards, so reports, rules and the dashboard behave as before:
  - `save-timeout` (default 0 = off): an unanswered save counts as failed, so a stalled request cannot hold back later saves. The sidebar uses 10 s. A failed save takes the existing error path and reloads the saved order.
  - `mirror-lists` (default off): other lists with the same URL and param (the same group in the All / Assets / Debts tabs and the mobile sidebar) follow a move right away, and all copies save through one queue, so saves cannot land out of order.
  - `dragStart` ignores drags from a row that is not draggable (an image or selected text inside it), `dragOver`/`drop` ignore drags from another list, `dragEnd` clears the dragged row, and the drag carries a custom data type so Firefox starts it without text fields accepting the drop.
- New Stimulus `account_sort_mode_controller.js`: handles and hint bar stay hidden, and rows are not draggable, until sort mode is on. Starting sort mode opens collapsed groups and leaving it closes them again; leaving it also drops and saves a row still held with the keyboard. It re-applies after a Turbo morph refresh and resets when a cached page is restored. The state is page-only, so navigating ends sort mode. The handle is a `DS::Button` like the one in the rules list; the toggle and bar are hidden in a tab without groups.
- The sidebar fragment cache key includes a digest of the manual order, so a move shows up immediately; its version suffix is bumped.
- No migration. en and de translations included.

## Scope

- Manual order applies to accounts **within** their account type group. Ordering the groups themselves (#3107 suggestion 3) is not part of this PR.
- Dragging is only in the sidebar; the dashboard balance sheet shows the same order without handles.
- Touches the same sidebar partial and appearance settings as #4018, the sort helper as #3993, and adds values next to the ones #4334 adds to `sortable_list_controller.js`. All overlaps are additive; whichever lands later merges `main` and keeps both sides.

## Validation

- Model: manual order with new accounts last (`BalanceSheetTest`); accessible-only ids, other groups kept, unknown groups and non-array ids rejected (`UserTest`).
- Controller: reorder saves, drops other-family accounts, rejects unknown groups; handles rendered only in manual mode (`AccountsControllerTest`); Appearance page offers and saves the order without touching other preferences and ignores unknown keys (`Settings::AppearancesAccountOrderTest`).
- System (`AccountManualOrderTest`): handles hidden until sort mode, keyboard reorder persists across reload and groups opened for sort mode close again; "Done" saves a row still held with the keyboard; a stalled save times out and the saved order is shown again; a move is mirrored in the other sidebar tabs; a drag outside sort mode does not move a row. The last two and the timeout test fail without their change.
- Existing system tests for reports, rules and dashboard reordering still pass.
- Full `bin/rails test`, system tests, Rubocop, erb_lint, Biome and Brakeman green.
