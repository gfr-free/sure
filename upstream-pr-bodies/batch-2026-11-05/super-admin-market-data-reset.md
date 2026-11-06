Related to #92

## Problem

Exchange rates and security prices are shared by every family on an instance. When a provider has delivered wrong or incomplete data (for example, after switching the exchange rate or securities provider), the existing "Clear data cache" only works per family. It also deletes balances and holdings, and the shared rates and prices it removes are then re-imported by parallel account syncs. During that time other families see unconverted (1:1) totals. There is no way to rebuild the shared market data once for the whole instance.

## Changes

- New Danger Zone action **Reset market data for all families** in Settings > Self-hosting. It is shown to and allowed for the super admin only, behind a high-severity confirmation.
- `MarketDataResetJob`:
  - Deletes only data the import fetches again: per security the windows `MarketDataImporter` requests, per currency pair the dates from `required_exchange_rate_pairs`, each clamped to how far back the provider reaches (`max_history_days`). Offline securities, securities whose provider is unavailable, providers without history and dates nothing needs keep their data.
  - Re-imports security prices and exchange rates with `MarketDataImporter` (full mode, cache cleared) before any account syncs, then queues a sync for every account, which rebuilds balances and holdings and fetches whatever is still missing.
  - If one import step fails, the job logs it (logger, Sentry, `DebugLogEntry`) and still runs the other step and the syncs.
  - Runs under a Postgres advisory lock and does not retry. A Redis guard (`SET NX EX`) lets only one reset be queued or running at a time; a second click says so, and a failed enqueue releases the guard and tells the admin nothing was deleted.
- The confirmation and the flash say the reset is queued and that totals may appear unconverted until the import finishes. Strings are added in English and German.

## Screenshots

Danger Zone as seen by the super admin (demo data).

| Before | After |
|---|---|
| ![before](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/market-data-reset/before.png) | ![after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/market-data-reset/after.png) |

## Notes

- The deletion and the re-import are not atomic. While the import runs, families may briefly see missing rates or prices; the warning text says so.
- Provider errors that `MarketDataImporter` handles internally (per pair or per security) are logged there and not reported again by the job.

## Validation

- Job tests: only the import windows are deleted, before the re-import, and one sync per account is queued afterwards; rows outside the windows, offline prices, balances and holdings are kept; prices and rates older than the provider's history stay; the import runs with the cache cleared; a failing price import still imports rates and queues the syncs; only one reset is queued until it has run; a failed enqueue releases the guard.
- Controller tests: the super admin can queue the reset; a second click, and a failed enqueue, show their own message; a family admin gets "not authorized" and nothing is queued; only the super admin sees the button.
- Hostings controller and job tests, RuboCop, ERB lint, Brakeman: clean.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
