## Problem

The cash flow warning insight (`CashFlowWarningGenerator`) projects the shared cash balance 30 days ahead. It has four bugs, each reproduced by a test that fails on main:

1. **Scheduled income is ignored.** Only occurrences with `amount > 0` (bills) were loaded, so the projection was "today's balance minus a full month of spending" without the paycheck that arrives in every 30-day window. A household holding less than one month of spending mid-month gets a high-priority "balance will go negative" card (with a push) every month, although the salary comes first. Example: 1,500 on checking, 2,500 monthly spending, salary 3,000 in 5 days. Main warns about -1,000; the real low point is about 1,083, so no warning.
2. **A snoozed bill counts on its old date.** Selection and placement used `due_on` instead of `effective_due_on`.
3. **An overdue bill snoozed into the horizon is dropped**, for the same reason.
4. **An open bill due today disappears.** It was taken out of the spending baseline but never subtracted, because the loop starts on day 1.

## Change

- Open income occurrences are added on their date, but only when they land in one of the projected cash accounts (shared, visible, family-currency Depository). A salary paid into an account that not every member can see does not cover the shared balance.
- Transfers stay excluded as before: loan payments and investment contributions are already part of the expense median, so counting them would double them.
- Occurrences are selected and placed by `effective_due_on`, using the same SQL as `BillNotCoveredGenerator`. Overdue occurrences that were not snoozed stay out, as there.
- Due today follows `BillNotCoveredGenerator`: an outgoing bill may already be in the balance, so it is not subtracted again, and it stays in the spending baseline instead of vanishing from both. Open income due today counts from the start.

## Resulting behavior

Only the cash flow warning changes. It fires less often (no monthly false alarms for salaried households), and the low point and its date are correct. Existing cards go away on the next nightly run when the condition no longer holds. Balances, reports, budgets, syncs and the other insight generators are untouched.

## Validation

- `test/models/insight/generators/cash_flow_warning_generator_test.rb`: 9 new behaviour tests (income into a shared cash account, income into a private account, income into a shared non-cash account, scheduled transfer, snoozed past the horizon, overdue snoozed into the horizon, overdue not snoozed, bill due today, income due today). They fail on main and pass here; the existing tests are adapted to the signed flows.
- `bin/rails test test/models/insight` on current main: 189 runs, 0 failures. Full CI green on the branch.
- Rubocop clean, Brakeman 0 warnings. No view or JS changes, so no screenshots.
