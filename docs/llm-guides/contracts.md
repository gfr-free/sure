# Working with contracts

Reference for the contract register: what it is, where the code lives, the
rules that must hold, and the decisions behind them. Read it before changing
anything under `Contract`, and update the decision log when a decision changes.

A contract is an agreement the family is bound by: insurance, mobile phone,
internet, energy, streaming, software, gym, membership, rent. Bills answers
"what is due and was it paid". Contracts answer "what am I bound by, until
when, how do I get out, and where is the paperwork".

Out of scope, on purpose:

- **Not an account type.** Most contracts have no balance; cash-value policies
  stay `Investment` accounts and can be linked as the related account.
- No sending of cancellations, tariff switching, bill negotiation or insurance
  needs analysis. These are commission or brokerage businesses (and in Germany
  §34d GewO applies). Sure records a cancellation; the user writes and sends it.
- Contracts never touch the balance sheet, net worth, budgets or bill detection.

## Key files

| Area | Files |
|---|---|
| Models | `app/models/contract.rb`, `contract_share.rb`, `contract_document.rb`, `contract/detailable.rb`, `contract/notice_schedule.rb`, `contract/legal_defaults.rb`, `contract/cost_report.rb`, `contract/document_prefill.rb` |
| Controllers | `app/controllers/contracts_controller.rb`, `app/controllers/contracts/{base,endings,sharings,documents}_controller.rb` |
| Views | `app/views/contracts/`, `app/views/bills/_contract_line.html.erb`, `app/views/bills/_view_switcher.html.erb`, `app/views/reports/_contracts.html.erb` |
| Reminders | `app/models/insight/generators/contract_generator.rb`, `app/jobs/contract_notice_reminders_job.rb`, `app/mailers/contract_mailer.rb`, `app/controllers/bills_feeds_controller.rb` |
| Assistant | `app/models/assistant/function/contracts_support.rb`, `get_contracts.rb`, `get_contract_details.rb`, `get_contract_audit.rb`, `create_contract.rb`, `update_contract.rb`, `search_family_files.rb` |
| Search index | `app/jobs/contract_document_index_job.rb`, `contract_document_unindex_job.rb` |
| Stimulus | `app/javascript/controllers/contract_defaults_controller.js`, `contract_kind_fields_controller.js` |
| Locales | `config/locales/views/contracts/`, `config/locales/models/contract/`, `config/locales/mailers/contract_mailer/` (`en` and `de`) |

## Placement and gating

- Contracts are the "Contracts" segment of the Bills view switcher, backed by
  `resources :contracts`. On that segment the header action adds a contract.
- Every contract controller includes `RecurringFeatureGuardable` and runs
  `ensure_recurring_enabled`: the per-user preview flag plus the family's
  `recurring_transactions_disabled` toggle. The assistant tools, the insight
  generator, the reminder job, the calendar feed, the account tab and the
  report section check the same gates.

## Data model

- `contracts`: `family`, `owner` (user), optional `account` (related account,
  grants nothing), optional `merchant` (the provider; there is no free-text
  provider), optional `replaced_by` (successor); `name`, `kind`, `status`; encrypted `contract_number` and
  `customer_number`; terms (`started_on`, `minimum_term_months`,
  `notice_period_value` + `notice_period_unit`, `notice_anchor`,
  `renewal_period_months`, `renewal_anchor_on`, `ends_on`); contacts (`portal_url`,
  `service_phone`, `service_email`, `claims_phone`); `document_links` (URLs,
  e.g. Paperless-ngx); `details` (kind-specific, see `Contract::Detailable`);
  `notice_not_required` (ends on its own or cannot be cancelled: no notice
  terms, no deadline, no reminders); `email_reminders`, `notice_reminders_sent`
  (stages sent per deadline, and per `price_guarantee:<date>`); `notes`.
  Document links carry an optional `role`, like documents.
- `contract_shares`: `contract`, `user`, `permission`
  (`full_control`, `read_write`, `read_only`).
- `contract_documents`: one row per uploaded file, with `role`
  (`ContractDocument::ROLES`: contract/policy, terms, amendment, price change,
  invoice, cancellation, other), `ai_searchable` and the `family_document` copy
  in the assistant's document store.
- `recurring_transactions.contract_id`: the bills that pay for a contract. A
  contract has many bills; its yearly cost comes only from them.
  The list shows that cost per year and as an average per month (yearly / 12),
  and a "price up" badge when, for any visible active bill, its latest price
  change in the last 12 months was an increase (`Contract.recent_price_increases_for`);
  the detail page lists those changes (`Contract#price_changes_for`).
- `insights.user_id`: an insight addressed to one member. Nil keeps an insight
  family-wide, as all other insights are.

Kinds and their icons live in `Contract::KIND_ICONS`; check constraints in the
migration mirror the enums.

## Lifecycle

```text
active --end (date)--> ended: shows "ends on <date>" until the date, "ended" after
  ^                      |
  +------ reopen --------+   (retention offer accepted)
```

- One step, whether the contract was cancelled or runs out: `end_contract!`
  records `ends_on` and sets the status to `ended`; `reopen!` takes it back.
  `display_status` is `active`, `ending` (end recorded, not reached) or
  `ended`. A passed `ends_on` ends the contract without a job.
- Ending a contract ends its linked bills on the same date (the ones the
  acting user may change), so Bills stops expecting payments; reopening
  restores the bills that ended on that date. Past payments stay linked as
  history. The bill pane still flags a bill that runs past the end (one the
  user could not change, or one reopened by hand), with an action to end it.
- A successor can be named in the end dialog (an existing contract, or "add a
  new contract", whose form opens with the ended one preselected under
  "Replaces contract"), in a new contract's form, or later in the edit form.
- The list shows the savings of contracts ended in the last 12 months
  (`Contract.annual_savings_for`): the last yearly cost of the bills that
  ended with them, less what the open contract at the end of each
  replacement chain costs (counted once, even when it replaced several);
  negative totals read as extra cost. A new contract can only name a
  predecessor that is not replaced yet.
- Creating from a bill or a document maps the provider name to an existing
  merchant (`Contract.merchant_named`); the assistant creates a family
  merchant when none matches.

## Visibility and permissions

Same model as accounts, with **no admin override**:

- `Contract.accessible_by(user)`: owner, or a row in `contract_shares`.
  `editable_by(user)`: owner, `full_control` or `read_write`.
- A related account grants nothing; the share dialog lists members instead.
- New contracts follow `families.default_account_sharing`; so does a member
  joining the family (`Family#auto_share_existing_contracts_with`).
- Guests can only hold `read_only`.
- `read_only` sees numbers masked (`Contract.mask`); editors see them in full.
  The masking is a UI courtesy, not a boundary: every share, including
  `read_only`, can open the uploaded documents, and a policy PDF usually
  carries the numbers. The share dialog says so; do not present masking as
  protection against someone the contract is shared with.
- Bills keep their own visibility: `visible_recurring_transactions_for(user)`,
  and costs only count bills the viewer can see.
- Contract insights and email reminders go to the owner only.

## Notice deadlines

`Contract::NoticeSchedule` returns `term_ends_on`, `notice_deadline` and
`earliest_end_on`:

- Terms end the day before the next term starts; notice "N months to the end
  of the term" means the last day is the day before N months back from the day
  after the term end (to end on 31 Dec with 3 months: by 30 Sep; to end on
  28 Feb with 1 month: by 31 Jan).
- `end_of_term` walks term boundaries from the minimum term onwards on the grid
  of `renewal_anchor_on` (or `started_on`). Without a renewal period, a contract
  past its minimum term runs indefinitely and has no deadline to miss.
- `end_of_month` and `any_day` only have a deadline while a minimum term is
  still running.
- An ended contract (end recorded), one with a fixed `ends_on` and no
  renewal, or one marked `notice_not_required` has none.

`Contract::LegalDefaults` offers typical German terms per kind, only when
`families.country` is `DE`, only on the user's click, labelled "not legal
advice".

## Reminders

- `Insight::Generators::ContractGenerator` (nightly, preview families):
  `contract_notice_deadline` (within 60 days, high within 14),
  `contract_price_increase` (special-termination hint for insurance, telecoms,
  energy), `contract_charges_after_end`, `contract_price_guarantee_ending`
  (an energy contract's `price_guarantee_until` within 60 days). All carry `user_id: owner_id`; feeds, the badge, the API,
  `get_insights`, push delivery and the per-user Turbo stream honour it.
- `ContractNoticeRemindersJob` (daily) emails the owner 30, 7 and 1 day(s)
  before a deadline and before an energy price guarantee ends, once per
  stage, recorded in `notice_reminders_sent`.
  `email_reminders` switches it off per contract.
- The bills calendar feed adds each visible contract's deadline with a
  `VALARM` a week ahead.

## Assistant, MCP and documents

Rules, enforced by `test/models/assistant/function/contract_tools_test.rb`:

1. No tool returns a contract or customer number, the notes (free text), or
   personal details (`ContractsSupport::SAFE_DETAIL_KEYS` whitelists the rest).
   Sure has no redaction layer before LLM calls, so omission is the protection.
2. The tools sit in `PREVIEW_FUNCTION_CLASSES` (also served over `/mcp`) and
   re-check the Bills gates and contract access themselves.
3. The static system prompt is untouched; contracts are reached through tools.

- PDF imports classified as `contract` keep the readable terms in
  `extracted_data["contract"]` (the prompts forbid numbers). The import page
  offers "Create contract from this document"; `Contract::DocumentPrefill`
  re-validates every value and the PDF becomes the contract's first document.
- A contract document enters the assistant's document store only when an
  editor opts it in (`ContractDocument#set_ai_searchable!`, background job).
  The store is per family, so `search_family_files` drops hits from contract
  documents the asking user cannot see.

## Other surfaces

- Bill page/pane: contract line, "Record as contract" (prefilled, kind guessed
  from category and names), ended-contract warning.
- Transaction page: contract link next to "Applied to".
- Account page: a Contracts tab when visible contracts relate to the account.
- Reports: "Fixed costs & contracts" (yearly cost per kind; insurance premiums
  paid in the period, flagged "possibly deductible" for lines in
  `TAX_RELEVANT_INSURANCE_LINES`).
- `/contracts/overview`: printable emergency overview; numbers masked unless
  `numbers=1`, and then only where the viewer may see them.
- Export/import: `Contract` and `ContractShare` NDJSON records, `contract_id`
  on bills, document metadata in `attachments.json` (no binaries). Owners and
  shares only restore when the same members exist in the target family.

## Edge cases

| Case | Behavior |
|---|---|
| Contract deleted | Bills stay, `contract_id` nulled; documents purged and unindexed |
| Account deleted | `account_id` nulled; that account's bills are destroyed with it |
| Merchant deleted / merged | `merchant_id` nulled / moved to the merge target |
| Owner deleted | Contracts pass to an admin (or the longest-standing member) |
| Owner moves family | Contracts move; shares, bill links, family merchant (name kept as provider), unrelated account and successor links are cut |
| No linked bill | Cost unknown; "Add payment" creates a bill |

## Decision log

| Decision | Choice | Why |
|---|---|---|
| Account type vs. separate model | Separate `Contract` | Most contracts have no balance |
| Placement | Segment in Bills | Same domain; no new top-level nav |
| Numbers | Encrypted like the rest of the code (plaintext plus warning without keys) | Consistency with `Encryptable` |
| End linked bills at contract end | Offered, default off | User keeps control; the pane flags running bills |
| Visibility | Owner plus explicit shares, no admin override | Same as accounts; privacy inside the household |
| Account link grants access | No | One rule |
| Documents | One `ContractDocument` row per file | Per-document AI opt-in |
| AI and numbers | Never sent to the model | No redaction layer before LLM calls |
| Documents in AI search | Opt-in per document, filtered per user | Policies are full of personal data; the store is per family |
| Contract insights | Addressed to the owner (`insights.user_id`) | A family-wide card would name private contracts |
| Languages | `en` and `de` | Others fall back to English |
| Special termination after a price increase | Hint only, no own deadline | Rarely relevant (Gerald, 2026-10-01) |
| Price guarantee reminder | Energy only, insight + email like the notice deadline | Gerald, 2026-10-01 |
| Later | API v1, mobile app, demo data, change history, Paperless-ngx API, ntfy/Gotify/webhook reminders | Not needed for the first release |
