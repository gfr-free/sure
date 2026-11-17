## Problem

`InvestmentStatementTest#test_totals_cache_invalidates_when_an_exchange_rate_is_stored` fails intermittently in CI:

```
expected exactly twice, invoked once: InvestmentStatement::Totals.new(any_parameters)
```

The cached income, investment, net worth and transaction-search totals use `ExchangeRate.maximum(:updated_at)&.to_i` in their cache key, which keeps whole seconds only. A rate stored within the same second as the previous rate write leaves the key unchanged, so a total cached in between keeps leaving that rate's amounts out (totals skip amounts without a rate since #3983).

In the test suite this happens whenever the test runs in the same second the fixtures were inserted. Fixtures are inserted at the start of each test process and again after every non-transactional test, with `updated_at` set to the current time.

**Reproduced:** running only that test (`bin/rails test test/models/investment_statement_test.rb:796`, so it runs right after the fixture load) failed in 3 of 6 runs with the exact CI message. With this change it passed 6 of 6.

## Change

- New `ExchangeRate.cache_version`, which returns `maximum(:updated_at)&.to_f`. It keeps fractional seconds, in the same style as `Family#entries_cache_version`.
- Used at all five cache keys that had the `.to_i` variant: `IncomeStatement`, `InvestmentStatement#totals_query`, `Transaction::Search`, `BalanceSheet::NetWorthSeriesBuilder` and `BalanceSheet::NetWorthBreakdownSeriesBuilder`.
- `Budget::RolloverCalculator#inputs_fingerprint` already used `.to_f`. It now calls `ExchangeRate.where(to_currency: ...).cache_version`, so the rule lives in one place. The result is identical.
- Regression test in `ExchangeRateTest`: two rates stored 0.5 s apart within the same second change the version. It fails with `.to_i` and passes with `.to_f`.

## Behaviour

- No computed figure changes; only cache keys do.
- After deploy the affected caches are rebuilt once, because the key format changes from an integer to a float.

## Not changed here

These limits existed before this change and are left for separate follow-ups:
- Deleting rates does not move the key while the newest rate stays.
- A write that commits late with an earlier `CURRENT_TIMESTAMP` can still be missed.
- The `AccountShare` versions in the net worth keys still use `.to_i`.

## Validation

- Full `bin/rails test` is green. The only local failures were AI provider tests caused by the local environment's proxy variables, and they pass without them.
- `bin/rubocop` and `bin/brakeman` are green. There are no ERB or JS changes.
