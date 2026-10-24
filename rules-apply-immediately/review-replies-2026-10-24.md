# Upstream PR 4347: replies to the cubic-dev-ai review of 23.10. (15 threads)

Fix commits on the PR branch: 42242d4 (models/controllers/copy) and 3153c30 (drawer tag picker).
Pi: for each thread, match it by path + line + topic, first check whether gfr-free already
replied (then only resolve), otherwise post the reply below and resolve the thread.
Threads marked "declined" are resolved too after the reply (reasoned decline).

---

## 1. app/models/family/data_exporter.rb:760 (rules.csv lacks apply_immediately) — declined

Leaving this one as is. `rules.csv` is the human-readable rule list for the CSV rule import, and it already omits other run settings such as `stop_processing`; the lossless round-trip of a family export is `all.ndjson`, which carries `apply_immediately` and is read back by `Family::DataImporter` (covered in `data_importer_test.rb`). Adding the flag only to the CSV would need a new `RuleImport` column and mapping for a single setting while `stop_processing` stays missing, so that's better done for all run settings together in a separate change.

## 2. app/models/rule_run.rb:64 (fail_job! drains without offering) — fixed

Fixed in 42242d4. `fail_job!` now offers the result when its call drains the run and earlier jobs changed something. Whether a call drained the run is decided inside the row lock, so a Sidekiq retry of a job that already failed doesn't re-broadcast the toast. Tests: `an immediate run whose last job fails still offers what earlier jobs changed`, `retries of a job that already failed don't offer the result again`.

While at it: for a rule that mixes a normal action with an AI action, `Rule::Runner#run_counts` stores the synchronous changes as `transactions_processed` on the pending run, so they were never offered. `ApplyImmediateRulesJob` now offers those right away (test: `offers what a rule changed while its AI jobs are still pending`).

## 3. config/locales/views/rules/en.yml:48 (splits/transfers/trades wording) — fixed

Fixed in 42242d4. The sentence meant the flows, not the transactions: splitting, marking as a transfer and converting to a trade don't call the immediate path. The copy now says "Splitting a transaction, marking it as a transfer or converting it to a trade doesn't start it; those changes wait for the nightly run." (German updated too.)

## 4. config/locales/views/rules/en.yml:49 (AI cost wording) — fixed

Fixed in 42242d4 with the suggested wording: "may incur AI usage costs for each new or changed transaction they match". The German locale is updated the same way.

## 5. app/models/assistant/function/create_transaction.rb:206 (one job per created transaction) — declined

Leaving this one as is. The assistant function creates exactly one transaction per call, so there is no batch inside it to coalesce; a model creating several transactions makes several separate tool calls, like several manual creates in the web form. Each job only creates `RuleRun`s for rules that match the new transaction (rules matching nothing are skipped without a run), and a busy family lock makes the job retry via `retry_on Rule::Runner::LockBusy` rather than drop the run.

## 6. app/models/entry.rb:312 (snapshot hashes columns rules don't read) — fixed

Fixed in 42242d4. `import_locked`, `reconciled_at` and `reconciled_by_statement_id` no longer count as a change. `excluded` stays in, because `Rule::ActionExecutor::SplitTransaction` only splits transactions that aren't excluded, so un-excluding one can change a rule's result. I kept a deny-list rather than an allow-list: a column a rule starts reading later then still triggers the run, while an extra run on a bookkeeping change costs nothing but a no-op job. Tests: `reconciling a transaction leaves what rules read unchanged`, `excluding a transaction changes what rules read`.

## 7. app/models/entry.rb:644 (2N tagging queries in bulk_update!) — fixed

Fixed in 42242d4. With a block, `bulk_update!` loads the entries once, reads the tags of all of them in one query before the loop, and builds the after-snapshot from the tags it just assigned (or the unchanged ones), so there are no per-entry tagging queries anymore. Test: `bulk_update! with a block reads the tags of all entries in one query` (exactly one taggings query for three entries).

## 8. test/jobs/apply_immediate_rules_job_test.rb:60 (lower rule's matcher) — fixed

Good catch, fixed in 42242d4. The rule below now matches the renamed value `"WF Market"`, and the test also asserts the rename happened, so it only passes because of the rule's position.

## 9. test/models/rule_run_test.rb:98 (zero-change immediate run) — fixed

Added in 42242d4: `an immediate run whose jobs changed nothing offers no result` and `an immediate run that fails without changes offers no result`.

## 10. test/controllers/transactions_controller_test.rb:2026 (@entry.transaction) — declined

This one is fine as written: `Entry` declares `delegated_type :entryable`, which defines `Entry#transaction` as the reader for the `Transaction` entryable and shadows ActiveRecord's instance-level `transaction`. The app uses it the same way (`@entry.transaction.tag_ids = ...` in both transactions controllers), and the test's `update!` lands on the transaction record, as the passing assertions show.

## 11. test/system/transaction_drawer_rule_changes_test.rb:127 (duplicate wait_until) — fixed

Fixed in 3153c30: `wait_until` now lives in `ApplicationSystemTestCase`, and both copies (here and in `loan_payoff_chart_test.rb`) are removed.

## 12. app/controllers/api/v1/transactions_controller.rb:178 (rejected update enqueues) — fixed

Fixed in 42242d4. The enqueue is gated on a local `updated` flag that is only set when `@entry.update` succeeded. Test: `a rejected API update runs no immediate rules`.

## 13. app/controllers/transactions_controller.rb:270 (non-atomic tag merge) — fixed

Fixed in 42242d4. The merge moved to `Transaction#merge_tag_changes!`, which reads the stored tags and writes the merged set inside `with_lock`, the same row lock `toggle_tag!` and `Rule::ActionExecutor::SetTransactionTags` take, so a tag another writer adds in between isn't lost. Test: `merge_tag_changes! keeps a tag written after the picker's copy was loaded`.

## 14. app/javascript/controllers/tag_select_controller.js:275 (silent failed save) — fixed

Fixed in 3153c30. A failed save now shows an error below the picker ("Tags couldn't be saved. Change them again to retry, or reload the page."), which hides again after the next successful save. I didn't revert the selection: a failed request may still have been applied on the server, so reverting could show the wrong state; the picker keeps those tags as unconfirmed and sends them again with the next change. The menu is anchored to an inner wrapper, so the message doesn't shift the open menu. System tests cover both a 500 and an expired session.

## 15. app/javascript/controllers/tag_select_controller.js:275 (redirected login page counted as saved) — fixed

Fixed in 3153c30. A save now only counts when the response is OK, not redirected and JSON. For the record: with an expired session the 302 is currently followed as `PATCH /sessions/new`, which 404s, so it was already treated as failed; the stricter check covers a redirect that ends in a 200 HTML page. System test: `a tag save answered with an HTML page counts as failed` (fails without the check).
