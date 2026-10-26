## Problem

The transactions list is slow on small self-hosted servers, and almost all of that time is view rendering, not the database (about 0.1 s of queries per page of 100 rows).

- Each row renders a category menu and a tag menu twice (mobile and desktop cells). Every menu shipped an eager `<turbo-frame>` with a loading placeholder inside its closed popover, so a page of 100 rows carried 400 frames that are almost never opened, and the category menu rendered both badge variants into both cells. Profiling put about 70 % of a row's render time into these two menus.
- Every row (some 30 partials and components, roughly 14 ms each on a small CPU) was re-rendered on every visit, filter change and return from the drawer, although rows rarely change.

## Changes

**Lazy dropdown frames**
- `DS::Popover` gains `frame_id:` / `frame_src:` (both or neither). The panel is then an empty slot, and the Stimulus controller creates the `<turbo-frame>` on the first open, which makes Turbo fetch it (Turbo marks it `aria-busy` while loading). For the user nothing changes: the dropdown was already loaded lazily on open through `loading="lazy"` inside the hidden panel.
- `categories/_menu` and `tags/_menu` use it instead of rendering a frame per row.
- The category cell only renders the badge its breakpoints can show: the mobile cell (below `md`) never reaches the `lg` pill; the desktop cell keeps the icon badge for the `md`–`lg` range.
- The now unused `categories.menu.loading` / `tags.menu.loading` translations are removed.

**Cached rows**
- `transactions/_transaction.html.erb` wraps the row in `cache transaction_row_cache_key(...), expires_in: 12.hours, skip_digest: true` (as long as the account sidebar cache: repeat visits on the same day hit the cache, and the Redis footprint stays small).
- `TransactionsHelper#transaction_row_cache_key` lists everything the row shows or branches on:
  - records: entry, transaction, tags, merchant, transfer and its other leg (an inflow row's category cell depends on the outflow's kind and category), the security a brokerage activity shows a logo for;
  - accounts and categories by their displayed attributes (id, name, type and trade support / color, icon), because their record versions change on every balance sync or category pick, which would empty the cache for no visible change;
  - per-viewer state: locale, user, family currency and locale, `can_annotate_account?`, counterpart visibility (`@accessible_account_ids`), split parent flag, `in_split_group`, `view_ctx`;
  - a digest of the row's sources (`TransactionsHelper::TRANSACTION_ROW_SOURCES`: the row partials, the category/tag/investment-activity partials, the two helpers and the `DS::*` components), computed once at load, plus `BUILD_COMMIT_SHA` or the app version. A markup change therefore never serves old rows, also for source builds without the build arg, and nobody has to bump a version by hand. `skip_digest` is on because the ERB dependency tracker cannot digest `DS::*` components (same reasoning as `account_sidebar_tabs`);
  - the Brandfetch settings that shape logo URLs (logo size, hashed client id).
- Rows with a pending transfer match are not cached at all (`cache_unless transaction.transfer&.pending?`): their confirm/reject `button_to` forms embed the session's CSRF token, and the reject form submits without Turbo, so it cannot fall back to the `X-CSRF-Token` header. These rows are few and short-lived.
- No extra queries on a hit: the key only reads associations the index already preloads (plus the same `split_parent?` lookup the account view already did).

## Measured

Local, 99 rows, warm:

| | before | lazy frames | lazy frames + cached rows |
|---|---|---|---|
| wall time | 1.9 s | – | 0.5 s |
| view time | 1.9 s | 1.7 s | 0.35 s |
| HTML | 1630 KB | 1496 KB | 1496 KB |
| DOM elements | 14.2 k | 12.4 k | 12.4 k |
| partial renders | – | 3205 | 583 |

## Deployment note (self-hosted)

Rows land in the Rails cache store (Redis in production, roughly 2–4 KB per row compressed, expiring after 12 hours). Instances that run Redis with a small `maxmemory` and `allkeys-lru`, shared with Sidekiq on the same database, should give it some headroom (e.g. 256 MB) so cache pressure does not evict job keys.

## Validation

- `test/components/DS/popover_test.rb` (new): eager content vs. lazy frame slot, `frame_id`/`frame_src` must come together.
- `transactions_controller_test`: no eager dropdown frames in the list, frame id/src per menu, per-variant badges.
- `test/views/transactions/transaction_row_cache_test.rb` (new, with a memory store): every source pattern matches a file and the digest is part of the key; an unchanged row is served from the cache; edits to entry, category, tags, tag names, account and merchant render it fresh; a balance update does not; an inflow row's key follows the outflow leg's kind and category and the counterpart's name; a row with a pending transfer match is never served from the cache; the key changes when an account starts supporting trades; the key differs per viewer, locale, view context, grouping and build. The transfer-leg, merchant/balance, pending-transfer and trade-support tests fail without the corresponding change.
- Full `bin/rails test`: 13169 runs, 0 failures, 0 errors, 36 skips. Rubocop: no offenses. erb_lint: no errors. Brakeman: no warnings. Biome: the only report in `popover_controller.js` is a pre-existing formatting line also present on main.
- No visual change, so no screenshots.

Not done: batching the per-row cache reads (`read_multi` / `cached:` collection rendering). The list renders rows per date group and split group, so it would need a restructure for about 20 ms per 100 rows.

### Known limitation

Turbo resolves `data-turbo-frame="category_dropdown"` to the first frame with that id in the document. This was already the case before (two such frames per row); now a frame only exists for menus that were opened. Per-row frame ids would remove it and are left for a follow-up.
