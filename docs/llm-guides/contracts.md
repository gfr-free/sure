# Contracts (design)

Status: **planned, not implemented.** This is the agreed design for a contract
register that sits next to Bills. Read it before implementing any stage, and
update it when a decision changes. Section 12 lists the decisions and their
reasons, so they are not re-argued in review.

A contract is an agreement the family is bound by: insurance, mobile phone,
internet, energy, streaming, software, gym, membership, rent. Bills answers
"what is due and was it paid". Contracts answers "what am I bound by, until
when, how do I get out, and where is the paperwork".

## 1. Scope and non-goals

In scope:

- A family-scoped `Contract` record with terms, status, contacts and documents.
- Links to the payment series (`RecurringTransaction`) that pay for it.
- Owner-plus-explicit-share visibility, the same model as accounts.
- Later stages: notice-deadline calculation, reminders, AI tools, and
  extracting contract fields from PDFs.

Out of scope, on purpose:

- **Not an account type.** Most contracts have no balance. Cash-value policies
  (endowment, unit-linked, Rürup, bAV) are `Investment` subtypes and can be
  linked to a contract.
- No sending of cancellations, tariff switching, bill negotiation or insurance
  needs analysis. These are commission or brokerage businesses (and in Germany
  §34d GewO applies), not software features. Sure drafts a letter; the user
  sends it.
- Contracts never touch the balance sheet, net worth, budgets or bill detection.

## 2. Stages

| Stage | Contents |
|---|---|
| 1 | Data model, sharing, CRUD UI under Bills, documents, links to bills, export/import |
| 2 | Notice-deadline calculation, German legal defaults, reminders (Insights + push, email, ICS alarms), charges-after-end detection, missing-confirmation reminder |
| 3 | Kind-specific details (sum insured, deductible, beneficiaries, data volume …), contracts section on Property/Vehicle/Investment pages, "Fixed costs & contracts" report with a yearly tax overview of insurance premiums, printable emergency overview |
| 4 | AI: assistant/MCP tools, contract-field extraction from PDFs, cancellation-letter draft, opt-in document search |
| Later | API v1 endpoints, mobile app, demo data, change history, Paperless-ngx integration, extra notification channels (ntfy/Gotify/webhook) |

Stage 1 ships as three PRs:

1. Migrations, `Contract`, `ContractShare`, `contract_id` on bills, encryption,
   log filtering, merchant merge/delete handling, export/import, fixtures,
   model tests. No UI.
2. `ContractsController`, list/detail/form, sharing dialog, documents, the Bills
   segment, `en`/`de` locales, controller tests.
3. Bill pane integration ("Contract: X", "Record as contract", "contract ended
   but bill still running"), transaction page link, system test.

## 3. Placement and gating

- Contracts are a fifth segment, "Contracts", in the Bills view switcher
  (`app/views/bills/_view_switcher.html.erb`), backed by its own resource
  `resources :contracts`. When that segment is active, the header's primary
  action is "Add contract".
- `ContractsController` includes `RecurringFeatureGuardable` and runs
  `ensure_recurring_enabled`. Contracts therefore inherit the Bills gates
  exactly: the per-user preview flag and the family's
  `recurring_transactions_disabled` toggle. No separate gate or setting.
- Guests never reach Bills, so they never reach contracts through the UI.

## 4. Data model

### `contracts`

UUID primary key, current migration version.

| Column | Type | Notes |
|---|---|---|
| `family_id` | uuid, not null, FK | Tenancy |
| `owner_id` | uuid, not null, FK users | Who manages the contract in Sure. Defaults to the creator. Mirrors `Account.owner_id`. |
| `account_id` | uuid, FK, `on_delete: :nullify` | Optional related account (car → Vehicle, home → Property, policy → Investment). Grants **no** access. |
| `merchant_id` | uuid, FK, `on_delete: :nullify` | Provider as a merchant (logo, name) |
| `replaced_by_id` | uuid, FK contracts, `on_delete: :nullify` | Successor after a provider switch |
| `name` | string, not null | "Private liability" |
| `provider_name` | string | Free-text provider when there is no merchant |
| `kind` | string, not null, default `other` | See below |
| `status` | string, not null, default `active` | See section 5 |
| `contract_number` | text | Encrypted, see section 7 |
| `customer_number` | text | Encrypted, see section 7 |
| `started_on` | date | |
| `minimum_term_months` | integer | |
| `notice_period_value` | integer | Set together with the unit |
| `notice_period_unit` | string | `days`, `weeks`, `months` |
| `notice_anchor` | string | `end_of_term`, `end_of_month`, `any_day`. Without it a deadline cannot be computed correctly. |
| `renewal_period_months` | integer | nil = indefinite after the minimum term |
| `renewal_anchor_on` | date | Main due date when it differs from the start (insurance often 1 Jan; German car insurance 30 Nov notice) |
| `ends_on` | date | Fixed or effective end |
| `cancelled_on` | date | Cancellation sent |
| `cancellation_confirmed_on` | date | Provider confirmed |
| `portal_url` | string | Customer portal |
| `service_phone`, `service_email`, `claims_phone` | string | Contacts, claims hotline |
| `document_links` | jsonb, default `[]` | External document URLs (for example a Paperless-ngx document) |
| `notes` | text | |

Indexes: `family_id`, `[family_id, status]`, `owner_id`, `account_id`,
`merchant_id`, `replaced_by_id`.

`kind` values: `insurance`, `mobile`, `internet`, `energy`, `streaming`,
`software`, `fitness`, `membership`, `rent`, `other`. Each has a fixed icon
(insurance `shield`, mobile `smartphone`, …).

Stage 3 adds a `details` jsonb column for kind-specific fields. Do not add it
earlier.

### `contract_shares`

Mirrors `AccountShare`.

| Column | Notes |
|---|---|
| `contract_id`, `user_id` | FKs; unique on the pair |
| `permission` | `full_control`, `read_write`, `read_only` |

Validations: the user belongs to the contract's family; the user is not the
owner.

### `recurring_transactions.contract_id`

Nullable FK, `on_delete: :nullify`, indexed. A contract has many bills
(base fee plus device instalment); a bill belongs to at most one contract.

### Model sketch

```ruby
class Contract < ApplicationRecord
  include Encryptable

  belongs_to :family
  belongs_to :owner, class_name: "User"
  belongs_to :account, optional: true
  belongs_to :merchant, optional: true
  belongs_to :replaced_by, class_name: "Contract", optional: true
  has_many :contract_shares, dependent: :destroy
  has_many :recurring_transactions, dependent: :nullify
  has_many_attached :documents

  if encryption_ready?
    encrypts :contract_number
    encrypts :customer_number
  end
end
```

`Merchant` gains `has_many :contracts, dependent: :nullify` (merchants destroy
their recurring transactions, so this must be explicit).

### Validations

- `name` present; `provider_name` or `merchant` present.
- Term integers are whole numbers >= 0; notice value and unit are set together.
- `ends_on` is not before `started_on`.
- `owner`, `account`, `merchant`, `replaced_by` and every linked bill belong to
  the same family.
- Documents: same rules as `Transaction#attachments` (PDF and images, 10 MB
  each, at most 10). Extract the shared constants and check into a concern
  instead of copying them.
- Possible duplicate (same provider and contract number): warn in the form.
  Numbers are encrypted non-deterministically, so compare in Ruby within the
  family.

### Derived values (no columns)

- `annual_cost`: sum of `monthly_equivalent_amount * 12` over the active linked
  bills **the current user can see**, converted to the family currency like
  Bills does.
- `next_payment`: earliest next due date over the same bills.
- Displayed as ended when `ends_on` is in the past, even before status changes.

## 5. Lifecycle

```text
active ──cancel──▶ cancellation_sent ──confirm──▶ cancelled ──ends_on passes──▶ ended
  ▲                     │
  └────── withdraw ─────┘   (retention offer accepted)
```

- Stage 1: the user changes status; the UI shows "ended" once `ends_on` has
  passed.
- "Mark as cancelled" asks for the sent date and end date, and offers
  "End linked bills at contract end" (**default off**). When on, the linked
  bills get `end_mode: on_date` and `end_on`.
- Because that default is off, the bill pane shows "Contract ended, this bill is
  still running" with an action to end the bill.
- Provider switch: create the new contract and set `replaced_by` on the old one.
- Tariff changes and renewals with a new minimum term are edits plus notes in
  stage 1; a change history comes later.
- Stage 2 adds: a reminder when there is no confirmation 14 days after
  `cancelled_on`, and a warning when real charges post after `ends_on`
  (a refund claim).

### Edge cases

| Case | Behavior |
|---|---|
| Contract deleted | Linked bills stay; `contract_id` is nulled. Documents are purged. |
| Account deleted | `account_id` nulled. The account's bills are destroyed, so the contract loses those payments. Intended. |
| Merchant deleted | `merchant_id` nulled. |
| Merchants merged (`family_merchants#merge`) | Move `contracts.merchant_id` to the surviving merchant. Needs a test. |
| Owner deleted | Contract reassigned to an admin, as `reassign_owned_accounts!` does for accounts. |
| Owner moves family (`User#transfer_to_family!`) | Owned contracts move with them; their shares are deleted; links to bills that stay behind are nulled. |
| Contract without payments (bAV via payroll, annual premium from an unlinked account) | "Add payment" creates a manual bill (`manual: true`). No separate amount on the contract. Otherwise show "cost unknown". |

## 6. Visibility and permissions

Same model as accounts. There is **no admin override**: admins do not see
accounts that are not shared with them, and they do not see such contracts
either.

- `Contract.accessible_by(user)`: owner, or a row in `contract_shares`.
- A linked account grants nothing. The share dialog pre-selects the members
  the account is shared with, so the common case is one click.
- New contracts follow the family's `default_account_sharing`: when it is
  `shared`, share `read_write` with every member; otherwise private.
- Guests can receive at most `read_only`.

| Role | See | Full numbers | Edit, documents, notes | Share, delete |
|---|---|---|---|---|
| Owner | yes | yes | yes | yes |
| `full_control` | yes | yes | yes | yes |
| `read_write` | yes | yes | yes | no |
| `read_only` | yes | masked only | no | no |

Bills inside a shared contract keep their own visibility: a user sees only the
linked bills they can access; if some are hidden, show "Further payments not
visible". Sharing a contract never reveals amounts from a private account.

Known residue: a bill without an account is visible to the whole family, so its
amount and merchant show in Bills even when the contract is private. The form
hints to assign such a bill to an account for privacy. The bill pane shows the
contract line only to users who can see the contract.

## 7. Privacy and security

- **Encryption:** `encrypts :contract_number` and `:customer_number`,
  non-deterministic, behind `encryption_ready?` like the rest of the code. When
  encryption is not explicitly configured, the numbers are stored in plaintext
  and the number section of the form shows a warning (same pattern as the Trade
  Republic settings panel, with `shield-alert`).
- **Logs:** add `contract_number` and `customer_number` to
  `config/initializers/filter_parameter_logging.rb`.
- **Display:** numbers are masked (`•••• 4711`) in lists and detail views and
  carry `privacy-sensitive`. The full value appears only in the edit form, and
  only for roles allowed to see it.
- **AI:** the numbers never leave the server towards an LLM. See section 10.
- **Export:** the family export contains the numbers in plaintext (user
  requested, and needed for a lossless round trip). Documents are not in the
  export: the attachment manifest is metadata only, like transaction
  attachments.
- Run Brakeman before every PR.

## 8. UI (stage 1)

List (`/contracts`):

```text
Bills                                          [+ Add contract] [⋯]
[Overview] [Calendar] [Paycheck] [All] [Contracts]

 12 active contracts · €3,480 per year

 🛡 Insurance                                         €1,620 / year
   Private liability · HUK24 · •••• 4711      €65 / year   [Active]
   Car insurance · Allianz · → VW Golf        €540 / year  [Active]
 📱 Mobile                                              €480 / year
   Phone plan · Telekom                       €40 / month  [Cancelled for 31 Mar]
 ▸ Ended contracts (3)                                  (collapsed)
```

- Grouped by kind, a shared marker per row, status via `DS::Badge`,
  `DS::Pill` "Preview" by the title.
- Empty state explains the feature and offers "Add contract" and "Record from a
  bill" (opens All bills filtered to active).

Detail: header (icon, name, merchant logo, status), contract block (masked
numbers, start, minimum term, notice, renewal, end), contacts, linked payments
(links into the bill pane), documents and external links, notes, actions
(edit, share, mark as cancelled, delete).

Form (modal, `frame: :modal`): basics (kind, name, provider, related account,
owner), term (start, minimum term, notice value/unit/anchor, renewal, main due
date, end), numbers and contacts, notes. Use the DS form primitives.

Sharing dialog: copy the structure of `app/views/account_sharings/show.html.erb`.

Bill pane (`bills/_detail.html.erb`), below the state chips: "Contract: X →" when
linked and visible; otherwise "Record as contract", which opens the form
prefilled with name, merchant and account, and guesses the kind (category
Insurance → `insurance`, `bill_type: subscription` → `streaming`, else `other`).

Transaction page: next to the existing "Applied to" block, "Contract: X →".

Localization: new `config/locales/views/contracts/{en,de}.yml`; new Bills keys
(`bills.views.contracts`, pane strings) in the `en` and `de` Bills files only.
Other locales fall back to English. Follow the design-system rules in
`AGENTS.md` (functional tokens, `DS::*`, `icon` helper, `t()`).

## 9. Reminders (stage 2)

Today no bill reminder is delivered anywhere: `notify_days_before` only changes
how an occurrence is displayed. The only push notifications come from Insights.
So:

- **Deadline calculation** from start, minimum term, renewal, main due date,
  notice value/unit/anchor, in the family's time zone (`families.timezone`).
- **German defaults** as suggestions, only when `family.country == "DE"`,
  labelled "not legal advice" and always overridable:
  - insurance: renews for one year; notice usually three months (§11 VVG);
    special termination right within one month of a premium increase (§40 VVG)
  - consumer contracts concluded since March 2022: indefinite after the
    minimum term, one month notice
  - mobile/internet: minimum term at most 24 months, then monthly
  - rent: three months for the tenant
- **Insights** (new types): `contract_notice_deadline`,
  `contract_price_increase` (for insurance, mobile, internet and energy it
  points at the special termination right), `contract_charges_after_end`,
  `contract_cancellation_unconfirmed`. `Insight::BodyWriter` only phrases
  precomputed facts. High-priority ones are pushed via
  `DeliverInsightNotificationJob`.
- **Email** reminders through a new mailer, for users without the mobile app.
- **ICS:** the bills feed (`BillsFeedsController`) adds notice deadlines as
  all-day events with a `VALARM`.
- Extra channels (ntfy, Gotify, generic webhook) are a later stage.

## 10. AI integration (stage 4)

Rules, all enforced by tests:

1. `contract_number` and `customer_number` never appear in any tool result,
   Insight body or prompt. This covers the builtin chat, `/mcp` (same registry)
   and one-shot features. There is no PII redaction before LLM calls in Sure,
   so omission is the only protection.
2. Every tool requires `ai_enabled?` and sits in `PREVIEW_FUNCTION_CLASSES`,
   like the bill tools.
3. The static system prompt stays byte-stable; contracts are reached through
   tools only.

Tools (follow `Assistant::Function::BillsSupport` for the recurring-disabled
error, access scoping and writable checks):

- `get_contracts`: kind, status, annual cost, next deadline.
- `get_contract_details`: terms, visible linked bills, price history, document
  names.
- `create_contract`, `update_contract`: cannot read or write numbers.
- `get_contract_audit`: upcoming deadlines, special-termination candidates,
  duplicates, contracts without payments, charges after end, unconfirmed
  cancellations.

Other AI pieces:

- **Cancellation letter:** the LLM writes the text with the placeholder
  `[contract number]`; Sure substitutes the real number server-side when
  rendering or downloading. The number never reaches the model.
- **Contract from PDF:** a `ContractExtractor` for `PdfImport` with
  `document_type: contract` (the classifier already produces that type)
  proposes fields; the user confirms them in the prefilled form.
- **Document search:** a per-document toggle "Make searchable by the
  assistant", **default off**, available only with `ai_enabled?`. On uses
  `Family#upload_document` (with the contract id in the metadata); off uses
  `remove_document`.
- **Search leak to prevent:** the vector store is per family, so
  `search_family_files` must post-filter hits: a hit from a contract document
  is kept only if the user can access that contract. Test: member B cannot find
  member A's private policy.
- Include contracts in the Bills AI review prompt; guess the kind when
  recording a contract from a bill.

## 11. Integration map

| Area | Integrate? | What | Stage |
|---|---|---|---|
| Bills | yes | Segment, pane line, ended-contract hint | 1 |
| Transactions (show) | yes | Contract link next to "Applied to" | 1 |
| Export/import (`Family::DataExporter`, `DataImporter`, `SureImport`) | yes | `Contract`, `ContractShare`, `contract_id`; extend `IMPORTABLE_NDJSON_TYPES` | 1 |
| Merchants | yes | Logo reuse; merge and delete handling | 1 |
| Insights + push | yes | Reminder channel | 2 |
| Bills ICS feed | yes | Deadline events with alarms | 2 |
| Account pages (Property, Vehicle, Investment) | yes | Contracts section on the overview tab | 3 |
| Reports | yes | Fixed costs & contracts; yearly insurance premiums for the tax return | 3 |
| Assistant / MCP / PDF import | yes | Section 10 | 4 |
| Dashboard | no | The Insights feed covers it | – |
| Budgets | no | Bills already reserve amounts | – |
| Goals | later | Maybe a sinking fund for annual premiums | later |
| API v1, mobile | later | Needs Minitest, rswag and OpenAPI | later |
| Demo data | later | A few contracts with manual bills | later |
| Plan hub, rules, settings | no | Contracts belong to Bills and follow its toggle | – |

## 12. Decision log

| Decision | Choice | Why |
|---|---|---|
| Account type vs. separate model | Separate `Contract` | Most contracts have no balance; cash-value policies are `Investment` subtypes |
| Placement | Segment in Bills | Contracts and bills are the same domain; no new top-level nav |
| Numbers encrypted | Yes | Sensitive identifiers |
| No explicit encryption keys | Plaintext plus form warning, as elsewhere in the code | Consistency with `Encryptable` |
| End linked bills at contract end | Offered, default off | User keeps control; the pane flags running bills |
| Visibility | Owner plus explicit shares, no admin override | Same as accounts; privacy inside the household |
| Account link grants access | No | One rule; the share dialog pre-selects account members instead |
| AI and numbers | Never sent | No PII redaction exists before LLM calls |
| Documents in AI search | Opt-in per document, filtered per user | Policies are full of personal data; the vector store is per family |
| Languages | `en` and `de` | Others fall back to English |
| Sending cancellations, switching, negotiation | Not built | Commission/brokerage businesses, §34d GewO |

## 13. Tests per PR

- PR 1: validations and family checks; `accessible_by` for owner, each share
  permission, non-shared member and admin (admin sees nothing unshared);
  `annual_cost` with several bills, hidden bills and mixed currencies;
  encryption round trip; nullify on contract/account/merchant delete; merchant
  merge; owner reassignment on delete and transfer; export/import round trip
  including shares and `contract_id`.
- PR 2: both gate states and the family toggle; CRUD; other family and
  non-shared member → 404; `read_only` cannot edit and sees masked numbers only
  (assert the full number is absent from the HTML); upload limits; sharing
  dialog saves permissions.
- PR 3: system test: record a contract from a bill, mark it cancelled, see the
  running-bill hint, end the bill.

Before each PR, run the full pre-PR checklist in
[development.md](development.md#before-opening-a-pull-request).

## Related Investment subtypes (independent)

Separate small PR: add `ruerup`, `bav` (`tax_deferred`), and
`private_pension_insurance`, `endowment_insurance`, `unit_linked_insurance`
(`tax_advantaged`) to `Investment::SUBTYPES` in the `eu` region with `en`/`de`
labels, and move `life_insurance` from region `in` to generic (`nil`). No
migration.
