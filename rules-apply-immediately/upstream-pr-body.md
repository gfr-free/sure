**Before:** rules only run overnight and after a provider sync or import. A transaction created or edited by hand, in a bulk edit, via the API or through the assistant keeps its empty fields until the next family sync, even when a rule would fill them. API users have no way to trigger rules at all (see the comments on #816).

**After:** each rule gets an opt-in setting, "Apply immediately to new and changed transactions" (off by default). Rules with it on also run right after such a change, only on the transactions that changed. Like "Apply rule", the active rules above them run first on the same transactions, so each immediate rule gives the result of its turn in the nightly run. The nightly and sync runs are unchanged and still run every active rule. Fields the person set themselves are locked when they save, and the immediate run respects locks.

Refs #816

### How

- **Migration** (reversible): `rules.apply_immediately` boolean, default `false`. Existing rules behave as before.
- **Enqueue:** `Rule.apply_immediately_later(family, transaction_ids)` enqueues `ApplyImmediateRulesJob` only when the family has an active immediate rule, so other families get no extra jobs. It is best-effort: the change is already saved and the nightly run applies the rules anyway, so a failed enqueue is logged and never fails the request.
- **Triggers:** web create/update/tags, the category quick edit, bulk update and bulk categorize, API v1 transactions create/update, and the assistant's create/update transaction functions. Provider syncs and imports are not touched; they already run all rules. Splits are not a trigger yet.
- **`Rule::Runner`** takes `transaction_ids:` and limits every rule's scope to them, including the active rules above (one array parameter, so large bulk edits stay under the bind limit). It keeps the existing order semantics: rules above run first, the top rule wins its fields, and "stop processing" applies. Rules below the last immediate rule wait for the nightly run. Rules that match none of the changed transactions are skipped without a `RuleRun`, so editing doesn't flood the run history. Runs are recorded with the new execution type `immediate`.
- **Feedback:** when an immediate run changed something, the job shows the existing sync toast instead of a full-page refresh, so a form the person still has open is not wiped.
- **No loops:** rule actions write through the executors, not through the controllers that enqueue the job.
- **UI:** an "Immediately" pill on immediate rules in the rules list, and the toggle in the rule form. The form notes that AI actions on an immediate rule cost one AI request per new or changed transaction they match, and that the emails of the rules above wait for the nightly run.

### Release notes

Rules can now apply immediately to transactions you add or edit, instead of waiting for the next sync. Turn it on per rule with "Apply immediately to new and changed transactions".

### Effects on other parts

- **Balances, reports, budgets:** unchanged. Immediate rules only set the fields rules could already set, earlier.
- **Sync, import, nightly job:** unchanged.
- **API:** the rules JSON gains `apply_immediately` (read-only). Rule runs can now have `execution_type: immediate`, which the rule runs filter accepts. Both are in the rswag schema and `docs/api/openapi.yaml`. Clients that treat `execution_type` as a closed enum will see the new value.
- **Data export/import:** `apply_immediately` round-trips in the NDJSON export; re-importing an export made before this setting keeps the stored value. The CSV rule import doesn't carry it, like `stop_processing` and `position` today.
- **Email notification rules:** set to immediate, they notify about a new matching transaction right after it is saved. Email actions of the active rules above that are not set to immediate are skipped in an immediate run and keep sending from the nightly run (emails claim no field, so the result for the rules below is the same; `stop_processing` still applies). Each transaction is still notified at most once per rule (existing `NotificationDelivery` dedup).
- **Performance:** one `exists?` check per transaction change; a job only when immediate rules exist, and each rule in that job only looks at the changed transactions.

### Coordination with other rule PRs

- Bulk update and bulk categorize keep the account share split from #4192 (`Current.annotatable_entries`, full vs. annotate-only); this PR only queues the immediate rules after the update.
- Email timing follows a suggestion from the author of #4150 and #4176: only rules set to immediate send emails right away. Dedup and the inactive-rule skip from #4211 are unchanged.
- This branch merges cleanly with the current heads of #4150 and #4176. The `apply_immediately` line in `Family::DataImporter` sits next to `stop_processing:`, which both of them touch, so whichever lands later should re-read that block.

### Screenshots

Demo data. Before = `main`, after = this branch.

| | Before | After |
|---|---|---|
| Rule list | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rules-apply-immediately/before/1-rules-list.png) | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rules-apply-immediately/after/1-rules-list.png) |
| Edit rule | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rules-apply-immediately/before/2-rule-form.png) | ![](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rules-apply-immediately/after/2-rule-form.png) |

### Validation

- New `ApplyImmediateRulesJobTest`: only the given transactions, active rules above run first and win their fields, their emails wait for the nightly run while an immediate rule emails right away, an email-only rule above still stops the rules below, an immediate rule sees a rename made by a rule above, rules below the last immediate rule wait for the nightly run, locks respected, no empty runs, toast only on change, retry while the family lock is busy.
- `RuleTest`: enqueue gating and enqueue failures.
- Controller and function tests: web create/update/tags, the category quick edit, bulk update, bulk categorize, API create/update, the assistant's create/update functions, saving the setting, the rule runs API filter, and export/import (a re-import of an older export keeps the stored setting).
- Full `bin/rails test` on current main: 12,464 runs, 0 failures, 0 errors. System tests pass in CI.
- RuboCop, erb_lint and Brakeman are clean. No JavaScript changed.
