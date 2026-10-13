Before: the sell form uses the global security search, so any ticker can be sold, including one the account never held. Selling more than the position (or back-dating a sale before the purchase) is saved silently and the holdings go below zero.

After: the sell form asks for the date first and then offers only what the account holds on that date, with the quantity ("Apple (AAPL), 10 held"). A sale that would take the position below zero on any day from its date through today is refused with a clear message and nothing is saved. Positions that went below zero through imports or syncs show a warning on the holdings tab and as an insight in the insights feed.

## Behavior

- The sell picker lists only securities held on the chosen date; no free search. A security that isn't listed needs its purchase recorded first (hint under the picker).
- An oversold sale is a validation error; nothing is saved.
- The limit is the holding on the sale date, and the position must also stay at or above zero on every later day (back-dated sales cannot push a later day negative). Splits are taken into account.
- Same check when editing a sale. Edits that only shrink an existing sale (same date and security) are not checked, so already-oversold data stays editable.
- Deleting or editing buys is not blocked, and imports/provider syncs are not checked. Negative positions from those show as a warning instead.

## Which paths are checked

| Path | Checked |
| --- | --- |
| Trade form: new sale | yes |
| Trade drawer: edit (qty, date, security, buy → sell) | yes |
| API `POST /api/v1/trades` (via `Trade::CreateForm`) | yes |
| API `PATCH /api/v1/trades/:id` | yes |
| Convert transaction to trade | yes |
| Bulk edit moving a sale's date | yes |
| Outflows under other labels (Transfer, Sweep Out) | yes |
| CSV import, provider sync | no (warning on holdings tab and in insights) |
| Linked accounts | never refused: the provider's holdings are the truth from today backwards, so a hand-recorded sale only raises earlier days |

## How

- `Trade::SaleLimit` computes the position without the sale via `Holding::ForwardCalculator` (now scoped to one security and able to exclude the edited entry), adjusts later days for splits, and compares the sold quantity with the lowest day from the sale date through today. Check and save run under a lock on the account row so two concurrent sales cannot count the same units.
- `Account#held_securities_on(date)` feeds the picker (latest holding row per security on or before the date, provider rows preferred); the picker reloads in a Turbo frame when the date changes. `Trade::CreateForm` only accepts a `security_id` the account holds.
- `Account#negative_positions` feeds a `DS::Alert` on the holdings tab and the new `Insight::Generators::NegativePositionGenerator` (type `negative_position`, medium priority, at most two accounts, only accounts every active member can see, provider-reported short positions ignored). The dedup key has no month, so an acknowledged insight stays quiet until its numbers change; the existing `about_shared_accounts` scope hides it as soon as an account stops being shared.
- New strings are translated in every locale that already has the sibling keys; an i18n test enforces that.

## Downstream effects

- Assistant/MCP tools that create trades through `Trade::CreateForm` get the same refusal.
- API clients that sell without a prior buy now get 422; tests were adjusted to buy first.
- `Insight::TYPES` gains `negative_position`, so the insights API and the assistant's `get_insights` filter accept it.

## Screenshots

| | Before | After |
| --- | --- | --- |
| Sell form | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sell-from-holdings/vorher/1-sell-form.png) | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sell-from-holdings/nachher/1-sell-form.png) |
| Selling 12 of 10 held | saved, position goes negative | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sell-from-holdings/nachher/2-sell-too-many.png) |
| Holdings with a negative position | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sell-from-holdings/vorher/3-holdings.png) | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sell-from-holdings/nachher/3-holdings.png) |
| Insights feed | no insight | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/sell-from-holdings/nachher/4-insight.png) |

## Validation

- `bin/rails test`: 11854 runs, 0 failures, 0 errors; system tests pass.
- New tests: `test/models/trade/sale_limit_test.rb`, `test/models/insight/generators/negative_position_generator_test.rb`, plus trades, API trades, conversion, bulk update, holdings, insights helper, account and i18n tests and a system test for the sell picker. They fail without the change.
- rubocop, erb_lint, Biome and Brakeman are clean.

Known pre-existing gaps, not changed here: API trade update/destroy and transaction bulk update do not check per-account write permission.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
