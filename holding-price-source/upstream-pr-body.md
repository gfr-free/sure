## Problem

The holding drawer never says which market data provider supplies a security's prices. A security without an assigned `price_provider` silently uses the first enabled provider (`Security#price_data_provider`), and nothing in the UI shows that. When a user has several providers enabled, the only way to find out where a price comes from is the database.

The provider name is also spelled differently in different places: the "provider disabled" warnings use `price_provider.humanize` ("Twelve data", "Eodhd", "Moex public"), the security search uses the translated names ("Twelve Data", "EODHD", "MOEX").

## Resulting behavior

The drawer's overview has a "Price Source" row directly under "Current Market Price":

| Situation | Shown |
|---|---|
| Provider assigned and available | `Yahoo Finance` |
| No provider assigned, fallback to the first enabled one | `Twelve Data (default)` |
| Assigned provider disabled or not configured (no API key) | `Tiingo (unavailable)`, the existing warning stays |
| Fetching paused for this security (offline, provider assigned) | `Twelve Data (paused)` |
| No provider fetches prices (synced-only tickers, nothing enabled) | `None, prices from account sync or trades` |

The provider-disabled warnings in the holding and trade drawers and the security search now use the same translated name.

![Before vs after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/holding-price-source/before-after.png)

Assigned provider:

![Assigned](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/holding-price-source/assigned.png)

## Changes

- `Security#price_source` (in `Security::Provided`) returns a small `PriceSource` value (`provider`, `status`). It resolves the provider once through the existing `price_data_provider`, so the label follows the same rule the price import uses. `Security.provider_key_for` is now public for this.
- An offline security without an assigned provider shows no fallback provider, since it may never have had provider prices (for example a synced-only ticker that the health check marked as failed).
- New `SecuritiesHelper#security_price_provider_name` and `#security_price_source_label`. The row uses `DS::DetailRow`.
- i18n: the row label and the five states in every locale that has the neighbouring keys; new `securities/nb.yml` and `securities/ro.yml` for the states; `securities.providers.tinkoff_invest` ("T-Invest (T-Bank)", as on the settings page) and `securities.providers.unknown`.

Display only. No migration, no change to price imports, balances, syncs or jobs.

## Overlap with open PRs

PR 4181 also adds `app/helpers/securities_helper.rb` and `test/helpers/securities_helper_test.rb`, and both add tests at the same spot in `holdings_controller_test.rb`. The conflicts are additive (keep both sides); whichever merges second needs a small rebase. PRs 4184, 4185 and 3098 merge cleanly with this one.

## Validation

- Model tests cover every status, including an offline security with an enabled fallback (so they fail if the offline branch breaks) and a health-check-paused security without a provider.
- Helper tests cover the labels, the unknown name and that every registered price provider has a translated name.
- Controller tests check the assigned, default and none rows in the drawer.
- `bin/rails test`: 12450 runs; the only 6 failures also fail on main in this environment (SimpleFIN pending env flags, OpenAI/Langfuse env).
- `bin/rubocop`, `erb_lint` on the changed views and Brakeman (0 warnings) are clean. No JS changes.
