# Account availability

Every account carries an availability level ("liquidity") that says how quickly
its money can be reached. Use it whenever code needs to know whether money is
available. Do not hardcode `accountable_type: "Depository"` for that question:
a term deposit is a depository account and is not available, a brokerage
account is not a depository account and can be sold within days.

## Levels

Stored on `accounts.liquidity`:

| Level | Meaning | Typical subtypes |
| --- | --- | --- |
| `immediate` | Reachable today | checking, cash, savings, credit card, line of credit |
| `short_term` | Reachable within days, possibly with price risk or notice | brokerage, crypto, money market, notice savings |
| `locked` | Locked until `accounts.available_on` | CD, building savings, VL, Indian FD/RD/NSC/KVP |
| `long_term` | Locked for years | retirement wrappers, HSA, property, vehicles, loans |

`available_on` is the release date of a locked account. With `auto_renew` and
`renewal_term_months` the deposit rolls over and never releases by itself.
`notice_period_days` is informational only.

## Where the logic lives

- `Account::Liquidity` (concern on `Account`): validations, the callback that
  writes the default, predicates and scopes.
- `Accountable.rules_for(subtype)` returns `Accountable::Rules`, the rule set a
  built-in subtype brings: default liquidity and tax treatment. Each accountable class
  overrides `default_liquidity_for(subtype)` (and `default_tax_treatment_for`
  where it has one). Add a new subtype there, not in a new constant elsewhere.
- `Account::RuleDetails` lists the rules for the account page's "Details" tab,
  with where each value comes from.

## Custom subtypes

A family can define its own subtypes per account type (`CustomAccountSubtype`,
table `custom_account_subtypes`, Settings > Account subtypes). Each one has a
name and a `rules` hash that combines the rules above: `liquidity` (one of the
four levels) and, for Depository and Investment, `tax_treatment`. A custom
subtype cannot add behaviour; a new rule needs code in `Accountable::Rules`
first.

An account points at one through `accounts.custom_account_subtype_id`. Then:

- `Account#subtype_rules` returns the custom subtype's rules, so the default
  availability follows them (`Account#default_liquidity`).
- `TaxTreatable#tax_treatment` returns its tax treatment for Depository and
  Investment, and `Family#tax_advantaged_account_ids` uses the same rule, so
  budget and cash flow agree with the account page.
- `short_subtype_label` / `long_subtype_label` show its name.

The built-in subtype stays on the accountable underneath: provider syncs keep
writing it, and it comes back into force when the custom subtype is removed
from the account or deleted. Editing a custom subtype's rules moves its
accounts to the new default unless their level was set by hand. The built-in
subtypes are templates (`CustomAccountSubtype.build_from_template`).

API (`custom_subtype`), the assistant's `get_accounts`, CSV and NDJSON export
(`CustomAccountSubtype` records) and the Sure import carry name and rules.

## Defaults and manual choices

New accounts, and accounts whose subtype changes, take the subtype default.
The form's "availability" select writes `liquidity_choice`: a level locks
`liquidity` in `locked_attributes`, so later subtype changes and provider syncs
leave it alone; `automatic` unlocks it and restores the default. Provider code
that changes `accountable.subtype` directly is covered by a callback on the
accountable.

`liquidity` is excluded from `lock_saved_attributes!`: the default written on
create must not look like a user choice.

## Asking the question

Pass the date you are asking about; release dates are evaluated per day, which
keeps historical figures right (today's level, applied with each day's date).
"Today" comes from `Account.liquidity_today_for(family)`, which uses the
family's time zone rather than the server's.

```ruby
today = Account.liquidity_today_for(family)

family.accounts.visible.available_assets_on(today)  # wealth you can reach at short notice
family.accounts.visible.immediate_assets_on(today)  # money for this month's budget
family.accounts.visible.bound_assets_on(today)      # the rest of the assets
family.accounts.visible.short_term_liabilities      # credit cards, overdraft lines

account.available_on?(today)
account.effective_liquidity(today)  # a released locked account reads "immediate"
account.next_release_date(today)
```

Assets and liabilities are separate scopes on purpose: a combined scope would
count credit cards as available wealth.

## Preview gating

The columns, migration backfill and defaults apply to everyone. Behavior and
UI are behind the preview switch: the form section, the custom subtypes
settings page and the account form's custom subtype select, header badge, Details tab,
and the budget's and paycheck planner's switch from "depository" to
`immediate_assets_on` read the viewer's `preview_features_enabled?`. Insights
already run only for preview families. API and assistant fields are always
returned (additive). A custom subtype already assigned to an account keeps
its rules when preview is off: like the stored level, it is the account's
classification.
