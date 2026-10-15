# Replies for upstream PR 4206 (commit e9ab734)

## Reply to Codex P1 (discussion_r4267630863)
Good catch, fixed in e9ab734. The aggregate generators (cash flow, spending anomaly, savings rate, net worth milestone, budget) now store `accounts_digest`, a SHA256 of the shared account ids, in their metadata. When only that digest differs from the stored row, `GenerateInsightsJob#upsert_insights` rewrites the body (and facts/title) but keeps read and dismissed state, since the signal itself did not change. That covers both cases: rows written before this PR have no digest, so they are rewritten on the first run after deploy, and a later share grant/revoke changes the digest and rewrites them again. No separate backfill or migration is needed. Test: `GenerateInsightsJobTest#test_a_changed_account_set_rewrites_the_body_but_keeps_acknowledged_state`, plus a generator test that revoking a share changes the digest.

## Reply to Codex P2 (discussion_r4267630872)
Fixed in e9ab734: the guard now uses `income_statement.eligible_accounts` intersected with the shared accounts, the same visible / included-in-reports / not-tax-advantaged filters `IncomeStatement::Totals` applies. A family whose only shared accounts are excluded from reports gets no budget insight. Test: `test_no_budget_insight_when_the_only_shared_accounts_are_excluded_from_reports`.

## Reply to CodeRabbit (discussion_r4267599114)
Fixed in e9ab734, same change as the Codex P2 thread: the guard reuses `IncomeStatement#eligible_accounts`, so disabled, report-excluded and tax-advantaged shared accounts no longer count.

## Reply to jjmata (issuecomment-6182205525)
Thanks for the review. Both points are addressed in e9ab734:
1. Budget guard: it now reuses `IncomeStatement#eligible_accounts` (visible, included in reports, not tax-advantaged) instead of any shared account.
2. Stale aggregate rows: instead of a one-time expire, the aggregate generators store a digest of the shared account set in metadata. When only the digest changes, the job rewrites the body but leaves read/dismissed state alone. Rows from before this PR have no digest, so they are rewritten on the first nightly run after deploy, and later share changes are handled the same way.
Full suite green locally (11,837 runs), Rubocop and Brakeman clean.
