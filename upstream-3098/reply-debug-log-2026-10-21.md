Good point, thanks. I went through the `Rails.logger` calls this PR adds or touches and moved the ones that explain a market data sync problem to an end user into `DebugLogEntry`, so they show up under `/settings/debug`:

- Saving the market data schedule in Settings → Hosting fails (`MarketDataScheduler.sync!` raises): now also logged as `market_data_schedule` / `error`, including the error message.
- Sidekiq startup can't create the `import_market_data` cron job: same category, so a missing daily price import is visible without server logs.

I kept the remaining calls in `Rails.logger` on purpose:

- Per-search provider failures in `Security.search_provider` run on every keystroke of the securities search and would flood the debug log. When a failed search actually affects a security (the resolver marks it `resolution_pending`), that is already written to the debug log with the failed providers.
- Twelve Data "invalid price/rate for date X" warnings fire once per bad data point, and the rate-limit "waiting Ns" message is informational, not an error.
- The info lines in `CronScheduler` ("created cron job with schedule …") are operator diagnostics, not errors.

Price fetch failures (`security_price_fetch`), metadata fetch failures, Yahoo chart fetch failures and resolver technical failures were already going to the debug log in this PR.

Tests cover the new entries. CI is green.
