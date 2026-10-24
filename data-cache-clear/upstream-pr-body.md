Fixes #92

## Problem

**Settings → Self hosting → Clear data cache** runs `DataCacheClearJob`, which

1. deletes **every** exchange rate and security price on the instance (`ExchangeRate.delete_all`, `Security::Price.delete_all`) plus the family's balances and holdings, and
2. enqueues `family.sync_later` right away.

The family's account syncs then run in parallel, each fetching its own rates. When two accounts need the same currency pair, the second one hits the import lock in `ExchangeRate.import_provider_rates`, skips the import and calculates without a rate. The display paths fall back to a 1:1 rate (`COALESCE(er.rate, 1)`), so foreign balances are added unconverted (1,000,000 THB counted as 1,000,000 EUR), and the cached sidebar and net-worth values keep the wrong figures.

The button is available to any **family admin**, not only the super admin. Because rates and prices are shared tables without a family, one family's admin wipes the market data of every other family on the instance. Those families show 1:1 totals until the next scheduled sync or market-data import.

## What changes

- New `Family::MarketDataRefresher`: downloads again the security prices and exchange rates the family's accounts use, with `clear_cache: true`, so stored values are **overwritten in place** instead of deleted. Each security and each currency pair is fetched **once**, over the widest window any account needs. A failure on one security or pair is logged (`DebugLogEntry` with the provider + Sentry) and the others continue.
- `DataCacheClearJob` now runs: refresh market data → delete the family's balances and holdings (in one transaction) → `family.sync_later`. The refresh runs first because the holdings decide which prices are needed, and the syncs should start with the refreshed rates. If the refresh raises unexpectedly, nothing has been deleted yet.
- `Account::MarketDataImporter`: `exchange_rate_pair_dates` and `price_windows` are public so the refresher can merge them across accounts. `import_exchange_rates` behaves as before.
- `Security::Price::ImportWindows::Window#merge`: shared by `MarketDataImporter` and the refresher instead of two copies of the same min/max merge.
- `clear_cache` in both importers now replaces stored values **only from the provider's first returned date on**:
  - `ExchangeRate::Importer`: inside that range, dates the provider skips (weekends, holidays) carry the provider's last rate forward instead of keeping the stale stored rate (as `Security::Price::Importer` already did).
  - `ExchangeRate::Importer` and `Security::Price::Importer`: stored history **before** the provider's first value is kept. Before, a stored value at the window start was carried forward over all those dates, flattening real history (e.g. from an earlier provider) for every family. This also applies to `ImportMarketDataJob(clear_cache: true)`.
- The warning and confirmation texts say that the family's balances and holdings are recalculated, the market data they use is reloaded, and only the family is affected (all 19 locales).

## Effects

- **Balances, net worth, reports:** after a cache clear the family's syncs start with rates present, so no 1:1 totals. Other families' balances and holdings are not touched; shared rates and prices are refreshed, not deleted.
- **Jobs:** the job takes longer (provider fetches run inside it, deduplicated per security and pair). The following account syncs find the rates and skip re-fetching.
- **No migration, no API change.**

## Known limitations (unchanged by this PR)

- Price rows stored under a currency the provider no longer returns are not removed (before, they were deleted instance-wide).
- If another sync holds the import lock for the same pair and start date, `import_provider_rates` still skips silently. The stored rates are no longer deleted, so the sync falls back to them instead of 1:1. Handling the skip itself is a separate change.
- Deleting holdings drops a manually entered cost basis; the rebuilt holdings come back as calculated. The old job did the same.

## Tests

- `test/jobs/data_cache_clear_job_test.rb` (new): rates are reloaded before the sync is enqueued (red on main); other families' rates, prices, balances and holdings are kept (red on main); held securities are refreshed before the holdings are deleted; the family's balances and holdings are deleted.
- `test/models/family/market_data_refresher_test.rb` (new): one fetch for a pair shared by three accounts, one price import (with `clear_cache`) for a security held in two accounts, a failing pair is logged and the others continue.
- `test/models/exchange_rate/importer_test.rb`: `clear_cache` carries the provider rate over skipped dates; keeps stored rates before the provider's first rate (red without the fix).
- `test/models/security/price/importer_test.rb`: `clear_cache` keeps stored prices before the provider's first price (red without the fix).
- `test/controllers/settings/hostings_controller_test.rb`: updated for kept market data.
- Full suite: 13,167 runs, 0 failures, 0 errors. RuboCop, Biome and Brakeman clean; ERB lint not applicable (no ERB change). No screenshots: the only UI change is the wording of the existing warning and confirmation dialog.
