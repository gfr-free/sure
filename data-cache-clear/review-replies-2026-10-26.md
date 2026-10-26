# Replies on upstream PR 4474, round 2 (post each on its thread, unchanged, no footer; skip a thread if gfr-free already replied there)

## A. jjmata — app/jobs/data_cache_clear_job.rb (no provider configured, text promises a reload) → resolve
Good catch. Without an exchange rate or security price provider the refresh does nothing, so the settings page now shows a separate warning and confirmation for that case: balances and holdings are recalculated and the stored rates and prices are kept (all 19 locales, dc8630e72, with follow-ups e55b9f352 and the latest commit for setups without a provider name or with an unknown one). With a provider configured the texts are unchanged.

## B. jjmata — app/models/family/market_data_refresher.rb (import lock skip) → do NOT resolve
Agreed, this is the known limitation listed in the description. Since the stored rates are no longer deleted, a skipped pair falls back to its previous rates instead of 1:1, so the original race is gone, but the refresh of that pair is lost. #4465 removes the skip itself: concurrent imports of a pair wait for each other instead of returning early, and a `clear_cache: true` import still fetches after the wait. I would rather fix it there than add a second retry mechanism here; once #4465 is merged this PR needs no change of its own.

## C. jjmata — app/models/account/market_data_importer.rb (needs_exchange_rates? twice) → resolve
Fixed in fd15d0f47: the guard now runs only in `import_exchange_rates`, before the provider lookup. `exchange_rate_pair_dates`, which the family refresher also calls, no longer repeats it; its pair list is built from the same three sources the guard checks, so it is already empty when no rates are needed.

## D. coderabbitai — app/jobs/data_cache_clear_job.rb (family lock does not block account syncs) → resolve
Agreed, `sync_later` locks only the record it syncs. Fixed in fd15d0f47: inside the family lock the job now locks the family's accounts in id order before it checks for a running sync, so neither a family nor an account sync can start between the check and the delete. A new test checks that the accounts are locked before the check (red without the lock).

## E. coderabbitai — app/controllers/settings/hostings_controller.rb (NoMethodError without a provider name) → resolve
Good catch, fixed in e55b9f352: the page only asks `ExchangeRate.provider` when a provider name is set, so an instance without one gets the provider-less text instead of an error. Covered by a new controller test (red before the fix).

## F. coderabbitai — app/controllers/settings/hostings_controller.rb (unknown exchange rate provider hides the security provider) → resolve
Fixed in the latest commit: the exchange rate and security providers are checked separately, so an unknown exchange rate provider no longer hides a working price provider. New controller test for that case.
