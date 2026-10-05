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
  subtype brings: default liquidity and tax treatment. Each accountable class
  overrides `default_liquidity_for(subtype)` (and `default_tax_treatment_for`
  where it has one). Add a new subtype there, not in a new constant elsewhere.
- `Account::RuleDetails` lists the rules for the account page's "Details" tab,
  with where each value comes from.

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
UI are behind the preview switch: the form section, header badge, Details tab,
and the budget's and paycheck planner's switch from "depository" to
`immediate_assets_on` read the viewer's `preview_features_enabled?`. Insights
already run only for preview families. API and assistant fields are always
returned (additive).

## Account forecast

`Account::Forecast` answers "what is left in this account after the payments
expected on it?" (the bills account). It starts from today's balance and
walks the open bill occurrences that touch the account: expenses paid from
it, income paid into it, and recurring transfers out of it (`account_id`) or
into it (`destination_account_id`).

- Window: up to the day before the next declared payday on the account
  (manual income series), else 30 days; `until_date` overrides it.
- No statistical daily spend, so a pure bills account does not read as
  running dry.
- Only `forecastable?` accounts: visible assets whose effective level today
  is `immediate`. Credit cards stay out.
- Each account in its own currency; occurrences in another currency are
  converted at today's rate or counted in `unconvertible_count`.
- `Account::Forecast.for_family(family, user:)` builds every account's
  forecast from one occurrence query and one allocation-sum query. Pass the
  user wherever a person sees the result, so series on accounts they cannot
  see stay out.

It feeds the account page's Forecast tab, the Bills page's account coverage
card, `Insight::Generators::AccountShortfallGenerator` (which also silences
the family-wide cash-flow warning while an account warning stands),
`GET /api/v1/accounts/:id/forecast` and the assistant's
`get_account_forecast`.

## Interest

`Account::Interest` (concern on `Account`) holds an account's interest terms;
`Account::InterestProjection` works out what they produce; `InterestMath` does
the day-by-day arithmetic without touching the database.

- Rate history in `account_interest_rates`: `credit` (paid on a positive
  balance) and, on depository accounts, `debit` (overdraft). A planned change,
  such as the end of a teaser rate, is an entry dated in the future. Rates are
  nominal, in percent per year.
- `accounts.interest_payout_frequency`: daily, monthly, quarterly, semiannual,
  annual or at_maturity. Blank follows the subtype (CD at maturity, building
  savings yearly, other depository accounts monthly). Interest is always paid
  into the account itself, on the last day of each period.
- Day count is fixed per currency: 30E/360 for EUR, actual/365 otherwise.
- Credit rates apply to depository and other-asset accounts. Loans keep their
  own rate model and schedule; `Account#interest_rate_on(date, applies_to:)`
  reads it, and reads a credit card's APR as its debit rate. Neither accrues
  through the projection.

The projection gives `accrued` (since the last payout, from the `balances`
table), `next_payout`, `payouts_between(to, balance_on:)` and, for locked
accounts, `value_at_maturity` (a term deposit paid at maturity capitalises
once a year counted back from the release date). Future days assume today's
balance unless the caller passes a balance path: `Account::Forecast` passes
its own, so interest payouts in the window show up as `:interest` events.

`Insight::Generators::InterestRateDropGenerator` warns 14 days before a credit
rate drops. The account form's interest section, the account page's Interest
tab and the insight are preview only; the API (`interest` on each account, the
amounts on the single-account response) and the assistant's `get_accounts`
always carry the terms.

## Taxes on returns

`Account::Taxation` (concern on `Account`) holds an account's tax settings,
`TaxProfile` a person's rates, and `Tax::Estimate` the arithmetic (decision
E20). Sure estimates; it never computes tax bindingly, and there are no
country presets.

- Tax belongs to a person, not the family: `tax_profiles` per user, from
  `valid_from_year` on, with a rate per income type (interest, dividends,
  gains, crypto; percent, nullable), a yearly allowance and whether the
  person's banks usually withhold the tax. The account's owner is the person;
  a joint account (`tax_joint_user_id`) splits its returns and exemption
  order with a second family member by `tax_owner_share` (nil = 50/50, E21
  T1). `Account#tax_shares` gives each person's share.
- Bank accounts store their tax treatment in `depositories.tax_treatment`
  (nil follows the subtype); investment and crypto accounts keep theirs.
  `Family#tax_advantaged_account_ids` honours the stored value.
- Per account: `tax_withheld_at_source` (nil follows the profile),
  `tax_allowance_allocation` (the exemption order at that bank) and
  `january_tax_debit` (such as the Vorabpauschale, a `:tax` event in the
  account forecast on 2 January).
- Booked returns are transactions labelled "Interest" or "Dividend", plus
  realised gains and losses of sales (`Trade#realized_gain_loss`, average
  cost): "gains" on investment accounts, "crypto" on crypto accounts. Sales
  without a known purchase price are left out and counted. Bank accounts
  offer the labels in the transaction drawer (preview).
- Loss pots (`LossPot`, E21 V-1) live per investment or crypto account, one
  per kind: `stocks` (share losses, offsets share gains only) and `general`
  (every other loss, offsets every return). `loss_pot_snapshots` keep the
  balances the person copied from a statement (`source: manual`); the latest
  one up to the estimate's date is the anchor, and returns up to its date
  are treated as already in it. Without `carry_forward` a balance only counts
  in its own year. Without a stocks pot, share losses go to the general pot.
  Pots never offset across accounts.
- `Tax::Estimate.new(user, year:)` collects the returns, offsets them
  against the loss pots (`pot_states`), applies the allowance in booking order (exemption orders for withholding accounts, the
  rest for accounts without withholding) and each kind's rate.
  `reserve` is the tax still due on gross-booked returns, nil when it cannot
  be worked out cleanly. `tax_for(account, amount, kind:)` estimates one
  person's tax on a further amount; `Tax::Estimate.tax_for_account` sums it
  over the people sharing the account.
- The budget takes the reserve of this year and last year off "really free"
  until the person marks the year as paid (`User#settle_tax_reserve!`).
  Withheld interest arrives net in the account forecast.
- `Insight::Generators::TaxAllowanceGenerator` points out exemption orders
  that are used up or add up to more than the allowance.

Settings → Taxes, the account form's tax section, the reserve in the budget
and the insight are preview only. The API (`tax` on each account) and the
assistant's `get_accounts` always carry the account's own settings,
including loss pots and the joint split. Sure exports carry loss pots with
their balances; the joint person is not imported, because people are not.
