Closes #4037. Follow-up to #3719: items 1, 2, 3, 4 and 6 of the issue in one PR. Item 5 (description drift of the merged PR) needs no code.

**Before:**
- A checking → brokerage contribution that the provider imported as "Contribution" disappeared from the investment-flow report as soon as the two legs were matched as a transfer. The matched brokerage leg is `funds_movement`, which the report filtered out, so a $500 contribution could turn into $0 and the card could disappear entirely. Matched brokerage "Withdrawal" legs had the same problem.
- Legacy transfers into investment/crypto accounts could keep old kinds (for example, an investment → investment outflow still `investment_contribution`, which budgets count as an expense). Provider syncs only repair the rows they replay.
- On the inflow leg of a categorizable transfer (brokerage or loan side), the inline picker and the transaction drawer let you pick a category. It looked saved but never reached a budget, because budgets count the outflow leg.
- Every repeat sync spent 7 queries per matched row, and the property system test was flaky.

**After:**
- The investment-flow report counts a matched contribution or withdrawal once when the cash side is outside the investment/crypto accounts. Movements between investment/crypto accounts stay excluded. Budgets are unchanged and still count a contribution once, on the cash leg.
- `bin/rails data_migration:reconcile_investment_transfer_kinds` (with `DRY_RUN=1` and `FAMILY_ID=` options) brings legacy kinds in line with `Transfer#kind_for_leg`. It is idempotent and opt-in.
- A matched transfer's category lives on its outflow leg. The inflow leg shows the outflow's category greyed out and read-only: the drawer keeps the usual category field, disabled, with a short explanation below it; the list row greys the badge and explains it in a tooltip. Both web write paths refuse a category for it.
- One query per matched row on repeat syncs, and a stable property test.

## Screenshots

Inflow leg on the brokerage account (demo fixture data):

![Inflow list row before/after](https://raw.githubusercontent.com/gfr-free/sure/ee5d6931003444983d3e24e2bf888eba1812379e/transfer-followups/inflow-list-before-after.png)

Transaction drawer of the inflow leg:

![Inflow drawer before/after](https://raw.githubusercontent.com/gfr-free/sure/ee5d6931003444983d3e24e2bf888eba1812379e/transfer-followups/inflow-drawer-before-after.png)

## How

**Item 1: investment-flow report.** `InvestmentFlowStatement#period_totals` keeps its kind filter (`standard`, `investment_contribution`) and ORs in matched legs. A matched leg counts when it is `funds_movement`, carries the label (Contribution on the inflow leg, Withdrawal on the outflow leg), sits on an Investment/Crypto account, and its transfer's other leg is on a non-investment account. This mirrors the endpoint rule of `Transfer.kind_for_account`. The transfer subquery is family-scoped. The viewer's account-visibility filter applies to both branches.

**Item 2: historical repair.** `Transfer::InvestmentKindReconciler`:
- **Repaired:** both legs of transfers whose destination is an Investment/Crypto account, when the leg's kind is one of `Transaction::TRANSFER_KINDS` and differs from `Transfer#kind_for_leg`.
- **Not repaired:** `standard`/`one_time` legs (the only kinds a user can pick), excluded entries, transactions with a locked `kind`, and transfers into other account types (loans, cards; see #3063).
- `user_modified` is not a skip reason. `Transfer::Creator` and the match dialog set it on every leg they create, so it does not mean the user chose a kind.
- Updates use `update_columns` and touch the entry, so entry-keyed caches expire. Kinds do not affect balances, so no sync is needed.

**Item 3: category ownership.** `Transaction#category_editable?` is true only for the outflow leg of a categorizable transfer. The new `#category_set_on_transfer_outflow?` marks the inflow leg. `CategoriesHelper#read_only_category` shows the outflow's category. It is hidden behind the generic transfer badge when the viewer cannot access the outflow's account, the same redaction the row uses for the counterpart name. The drawer renders `DS::CategorySelect` disabled, with a new `selected_category:` option for a selection outside its option list. `TransactionCategoriesController` answers 422 for an inflow leg. `TransactionsController#update` drops `category_id` for it and keeps other fields. The transactions index and account activity preload the outflow's category, so no N+1. Merchants and tags are untouched, as the issue asked.

**Item 4: repeat-sync cost.** `Account::ProviderImportAdapter` eager-loads both transfer legs with their entries and accounts, so a matched row costs one query instead of seven.

**Item 6: flaky property test.** The subtype dialog helper checks the expected value inside its retry, so a Turbo morph between opening the dialog and asserting no longer leaves the test waiting on a removed field.

## Effects on downstream processes

- **Reports:** investment-flow totals rise where matched contributions or withdrawals were missing. The card can reappear.
- **Budgets:** unchanged by items 1 and 3. Running the repair task can change budgets for affected history: an investment → investment outflow stops counting as an expense, and a legacy matched brokerage inflow stops counting. Reverting the code later does not restore the previous kinds.
- **Syncs/imports:** fewer queries (item 4). Kinds are derived as before.
- **Existing data:** no migration. Categories already stored on inflow legs stay in the database. The provider adapter sets one on brokerage "Contribution" rows, and the picker allowed it since #3719. They are no longer shown in the row and can still match the category filter, the API and exports.
- **Other write paths** that can still set an inflow leg's category are unchanged: API v1 update, bulk update, quick categorize, rules, assistant, imports. They behaved the same before #3719 for loans and are left for a follow-up.
- **API/mobile, self-hosters:** no API change. The repair task is opt-in.

## Tests

- `investment_flow_statement_test`: import → match → resync for a contribution, counted once in flows and once in expenses; a matched withdrawal; investment → crypto excluded; viewer visibility. The contribution, withdrawal and visibility tests are red without the fix.
- `transfer/investment_kind_reconciler_test`: legacy investment → investment outflow, legacy matched brokerage inflow, a legacy pair imported without a kind hint, user kinds/excluded/locked kept, other account types left alone, idempotency and cache touch, dry run.
- `transaction_test`, `transaction_category_view_test` (read-only outflow category, hidden for an inaccessible account), `transaction_categories_controller_test` (inflow 422, outflow still works), `transactions_controller_test` (inflow `category_id` dropped, notes saved; drawer shows the disabled field with the outflow's category and the explanation), `provider_import_adapter_test` (query count on repeat sync).
- `bin/rails test`: 0 failures, 0 errors. Rubocop, ERB lint and Brakeman: clean. Biome: no JS changes. System tests green in CI; property test 5 consecutive green runs.

## Owner decisions

- All items of #4037 in one PR; the description of #3719 stays as is (item 5).
- Item 1: a matched leg counts when the cash side is outside the investment/crypto accounts. Matched withdrawals are fixed too (report only; the budget withdrawal policy of #3845 is untouched).
- Item 2: a repair task rather than documentation only.
- Item 3: the category belongs to the outflow leg (left open in the issue). The inflow leg shows it in the same category field, greyed out and disabled, with a short explanation below.
