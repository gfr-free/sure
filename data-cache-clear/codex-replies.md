# Replies to the three Codex comments on upstream PR 4474 (post each on its thread, then resolve)

## 1. app/jobs/data_cache_clear_job.rb — delete and sync enqueue not atomic
Good catch, fixed in 8ec76db: `family.sync_later` runs inside the same transaction as the balance/holding delete again, so a failed enqueue rolls the delete back. New test `keeps the cached balances when the sync cannot be enqueued` (red before the fix).

## 2. app/models/family/market_data_refresher.rb — provider errors without an exception
Fixed in 8ec76db for prices: the `provider_error` returned by `import_provider_prices` is now written to the family's debug log with the provider (new test `logs a price refresh the provider reports as failed`). For exchange rates, `import_provider_rates` doesn't return the provider error; `ExchangeRate::Importer` already reports it to Sentry and the log, and the stored rates are kept (not deleted any more), so the following sync falls back to them rather than 1:1. Surfacing the rate error to the caller would change `import_provider_rates`' return value for every sync, so I kept that out of this PR.

## 3. config/locales/views/settings/hostings/en.yml — "Only your family is affected"
Agreed, reworded in 8ec76db (all 19 locales): "Only your family's balances and holdings are deleted; exchange rates and security prices are shared with the other families on this instance and are updated for them too."

## 4. jjmata, app/jobs/data_cache_clear_job.rb ~L15 — no provider configured (owner chose a separate text)
Good catch. Without an exchange rate or security price provider the refresh does nothing, so the settings page now shows a separate warning and confirmation in that case: balances and holdings are recalculated and the stored rates and prices are kept (all 19 locales, dc8630e72). With a provider configured the texts are unchanged.

## 5. coderabbitai, app/controllers/settings/hostings_controller.rb — NoMethodError without exchange rate provider
Good catch, fixed in e55b9f352: the page only asks `ExchangeRate.provider` when a provider name is set, so an instance without one now gets the provider-less text instead of an error. New controller test for that case (red before the fix).
