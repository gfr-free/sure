## Summary

Before: in the sidebar, the sparkline next to an account group summed every accessible account of that type, including accounts marked "exclude from reports" and shared accounts a member keeps out of their finances. The group total next to it skipped report-excluded accounts but still counted non-finance shared accounts, while the asset/liability total and net worth skipped both. Line and figure disagreed, and dashboard group weights could add up to more than 100 %.

After: group totals and group sparklines count exactly the accounts the classification total and net worth count: accessible, visible, included in reports, and included in the viewer's finances (owned, or shared with `include_in_finances`). Such accounts stay listed in the group; they just don't count, as report-excluded accounts already behave today.

Follow-up to the maintainer note on #4207 (sparkline access scoping), which called this out as out of scope there.

## How

- `BalanceSheet::ClassificationGroup.counted_accounts` holds the counting rule; `ClassificationGroup#total` and `AccountGroup#total` both use it.
- `AccountableSparklinesController#account_scope` keeps the `Current.accessible_accounts` scope from #4207 and adds `included_in_reports` and `included_in_finances_for(Current.user)`. The cache key and ETag keep the SHA-256 digest of the counted account rows from #4207, so the key also changes when a report exclusion or a share's finance setting changes.
- Sidebar fragment cache version bumped to `account_sidebar_tabs_v4` so cached group totals follow the new rule after deploy (the partial uses `skip_digest: true`).

## Effects

- **Sidebar:** group totals and sparklines drop non-finance shared accounts; sparklines also drop report-excluded accounts.
- **Dashboard balance sheet:** group totals and group weights now add up to the classification total.
- **Reports, net worth breakdown:** per-group totals use the same rule as the total assets/liabilities shown above them.
- **Balances, syncs, jobs:** unchanged; only read-side aggregation changes.
- Not changed here: per-account percentages on the dashboard still divide by the classification total for excluded accounts. That predates this PR (already true for report-excluded accounts).

## Tests

- New tests (report exclusion, non-finance share, cache following the finance setting, group and classification totals) fail on `main` and pass here; the cache test uses a memory store and fails without the row digest.
- All users of `AccountGroup#total` checked (sidebar, dashboard, reports net worth breakdown); no API or assistant path uses group totals.
- Full suite, Rubocop, ERB-Lint and Brakeman pass. No JavaScript changes, no migration, no visible change other than the numbers when shared or report-excluded accounts exist.
