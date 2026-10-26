Addresses #92 (the cache-clear race; the silent lock skip in `import_provider_rates` that the issue also describes is a separate change)

## Problem

**Settings → Self hosting → Clear data cache** runs `DataCacheClearJob`, which

1. deletes **every** exchange rate and security price on the instance (`ExchangeRate.delete_all`, `Security::Price.delete_all`) plus the family's balances and holdings, and
2. enqueues `family.sync_later` right away.

The family's account syncs then run in parallel, each fetching its own rates. When two accounts need the same currency pair, the second one hits the import lock in `ExchangeRate.import_provider_rates`, skips the import and calculates without a rate. The display paths fall back to a 1:1 rate (`COALESCE(er.rate, 1)`), so foreign balances are added unconverted (1,000,000 THB counted as 1,000,000 EUR), and the cached sidebar and net-worth values keep the wrong figures.

The button is available to any **family admin**, not only the super admin. Because rates and prices are shared tables without a family, one family's admin wipes the market data of every other family on the instance. Those families show 1:1 totals until the next scheduled sync or market-data import.

## What changes

- New `Family::MarketDataRefresher`: downloads again the security prices and exchange rates the family's accounts use, with `clear_cache: true`, so stored values are **overwritten in place** instead of deleted. Each security and each currency pair is fetched **once**, over the widest window any account needs. A failure on one security or pair (raised, or a price error the provider reports) is logged to the family's debug log with the provider, and the others continue.
- `DataCacheClearJob` now runs: refresh market data → delete the family's balances and holdings and enqueue `family.sync_later` (in one transaction, so a failed enqueue rolls the delete back). If a family or account sync is running, the job deletes nothing and reschedules itself a minute later: the running sync would write balances the delete removes, and `sync_later` would only join it. The check is repeated right before the delete, under a lock on the family and its accounts, so no family or account sync can start in between. The refresh runs first because the holdings decide which prices are needed, and the syncs should start with the refreshed rates. If the refresh raises unexpectedly, nothing has been deleted yet.
- `Account::MarketDataImporter`: `exchange_rate_pair_dates` and `price_windows` are public so the refresher can merge them across accounts. `import_exchange_rates` behaves as before.
- `Security::Price::ImportWindows::Window#merge`: shared by `MarketDataImporter` and the refresher instead of two copies of the same min/max merge.
- `clear_cache` in both importers now replaces stored values **only from the provider's first returned date on**:
  - `ExchangeRate::Importer`: inside that range, dates the provider skips (weekends, holidays) carry the provider's last rate forward instead of keeping the stale stored rate (as `Security::Price::Importer` already did).
  - `ExchangeRate::Importer` and `Security::Price::Importer`: stored history **before** the provider's first value is kept. Before, a stored value at the window start was carried forward over all those dates, flattening real history (e.g. from an earlier provider) for every family. This also applies to `ImportMarketDataJob(clear_cache: true)`.
- The warning and confirmation texts say that only the family's balances and holdings are deleted, and that the shared exchange rates and security prices are refreshed for the other families too (all 19 locales).
- Without any exchange rate or security price provider configured, the settings page shows a separate warning and confirmation: balances and holdings are recalculated, the stored rates and prices are kept (all 19 locales).

## Effects

- **Balances, net worth, reports:** after a cache clear the family's syncs start with rates present, so no 1:1 totals. Other families' balances and holdings are not touched; shared rates and prices are refreshed, not deleted.
- **Jobs:** the job takes longer (provider fetches run inside it, deduplicated per security and pair). The following account syncs find the rates and skip re-fetching.
- **No migration, no API change.**

## Known limitations (unchanged by this PR)

- Exchange-rate provider errors are reported by `ExchangeRate::Importer` (Sentry and log), not to the family's debug log, because `import_provider_rates` does not return them. The stored rates are kept, so the following sync uses them instead of 1:1.

- Price rows stored under a currency the provider no longer returns are not removed (before, they were deleted instance-wide).
- If another sync holds the import lock for the same pair and start date, `import_provider_rates` still skips silently. The stored rates are no longer deleted, so the sync falls back to them instead of 1:1. Handling the skip itself is a separate change.
- Deleting holdings drops a manually entered cost basis; the rebuilt holdings come back as calculated. The old job did the same.

## Tests

- `test/jobs/data_cache_clear_job_test.rb` (new): rates are reloaded before the sync is enqueued (red on main); other families' rates, prices, balances and holdings are kept (red on main); held securities are refreshed before the holdings are deleted; the family's balances and holdings are deleted; a failed sync enqueue keeps them; a running sync (before or during the refresh) makes the job wait instead of deleting; the accounts are locked before that check.
- `test/models/family/market_data_refresher_test.rb` (new): one fetch for a pair shared by three accounts, one price import (with `clear_cache`) for a security held in two accounts, a provider-reported price error is logged, a failing pair is logged and the others continue.
- `test/models/exchange_rate/importer_test.rb`: `clear_cache` carries the provider rate over skipped dates; keeps stored rates before the provider's first rate (red without the fix).
- `test/models/security/price/importer_test.rb`: `clear_cache` keeps stored prices before the provider's first price (red without the fix).
- `test/controllers/settings/hostings_controller_test.rb`: updated for kept market data; the provider-less text, including no provider name at all and an unknown exchange rate provider next to a working price provider.
- Full suite: 13,175 runs, 0 failures, 0 errors. RuboCop, Biome and Brakeman clean; ERB lint not applicable (no ERB change). No screenshots: the only UI change is the wording of the existing warning and confirmation dialog.
