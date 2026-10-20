## Summary

Before: Several providers still showed full bank or brokerage account numbers and IBANs. Setup screens printed them (Indexa Capital, Fio, Interactive Brokers, Trade Republic, Trading 212, Akahu). Questrade, Indexa Capital, Fio, Interactive Brokers, Trade Republic and Trading 212 built them into default account names such as "TFSA (12345678)", so the full number reached account lists, reports, CSV exports, the API and the assistant. Transaction "Additional details" dumped counterparty IBANs and account numbers as raw JSON (Monobank, Fio, Akahu), Akahu wrote the counterparty account into every transaction's notes, and Mercury wrote its `details` object (counterparty account and routing numbers, IBAN) into notes as a Ruby hash string.

After: Every one of those places shows only the last 4 characters, e.g. `•••5678`. Existing default account names that still end with the full number are rewritten by a data migration; anything a user wrote around the number is kept.

This is the follow-up to the shared `mask_last4` helper (#3826). It implements the remaining items of that privacy series (Indexa, Questrade, Monobank) plus the reuse candidates and boundary note from the maintainer's audit comment on #3826, extended by a provider-by-provider audit of all 25 sync integrations.

## Changes

- **`IdentifierMask`** (`app/models/identifier_mask.rb`): one masking rule for helpers and models. `ApplicationHelper#mask_last4` delegates to it. Sophtron (keeps its stored `****1234` format) and the Trade Republic connection card (strip spaces, hide values under 4 characters) reuse it with their own options.
- **Setup and linking screens** use `mask_last4`: Enable Banking, Lunch Flow, Indexa Capital, Plaid (incl. the duplicate warning), Akahu, Fio (3 views + settings panel, bank code kept), Interactive Brokers, Trade Republic, Trading 212.
- **Generated account names** use the masked number: Questrade, Indexa Capital, Fio, Interactive Brokers (`IbkrAccount.default_name`, also used by the Flex report parser that previously named the record after the bare id), Trade Republic, Trading 212.
- **Data migration** `MaskAccountNumbersInGeneratedAccountNames`: rewrites provider records and their linked accounts only where the name ends with `(<full number>)`, ends with `Fio banka <number>`, or (IBKR provider record) equals the bare number. Renamed accounts without the number are untouched.
- **Additional details**: `mask_extra_identifiers` masks every value under identifier-like keys (`iban`, `counter_iban`, `counter_edrpou`, `counter_account`, `other_account`, `account_number`, `routingNumber`, `sort_code`, `card_number`, `pan`, ...), matched on the key's final words so `counter_account_name`, `counter_account_type` or `account_number_last_4` stay readable. Applies to the raw dump and to SimpleFIN/Plaid structured rows. Fio's `<account>/<bank>` keeps the bank code.
- **Notes**: Akahu keeps only the last 4 digits of the counterparty account; Mercury only keeps `details` when it is a plain string.
- **Data migration** `RemoveMercuryRoutingDetailsFromNotes`: removes the trailing `details` hash from Mercury notes already stored and keeps the note in front of it. Notes the user edited (locked) are skipped. The details stay in the raw transactions payload.
- **Indexa Capital**: drops the duplicate `account_number` column (same value as `indexa_capital_account_id`, which every lookup already uses; reversible migration). The column is ignored so the code runs before and after the migration; processes still on the previous release write it until they restart. The invalid-number error message is masked too.
- **Boundary documented and tested**: values of 4 characters or fewer are shown in full (`mask_last4("123")` is `•••123`), so the helper is for identifiers only, never for secrets.

Deliberately unchanged, as the audit comment recommended: wallet address abbreviations, secret placeholders and the mobile money masker follow their own rules.

## Screenshots

Indexa Capital setup (name and number):

![Indexa setup before/after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/identifier-masking/indexa-setup.png)

Transaction "Additional details" (Fio and Monobank counterparty, demo data):

![Additional details before/after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/identifier-masking/transaction-details.png)

## Effects on other processes

- **Balances, syncs, matching:** none. Only display strings, generated names and Mercury notes change; lookups use the provider id columns, which keep the full value. The dropped Indexa column was never used for lookups.
- **Account names:** existing default names change once (migration), so exports, reports and API output show the masked form afterwards. Providers that rebuild names on sync (Questrade, Trade Republic) now produce the masked form.
- **Mercury notes:** existing unlocked notes lose the details hash once (migration); later syncs keep them that way.
- **Rules:** rules match accounts by id, not by name, so they are unaffected.
- **Related:** DebugLogEntry encryption (#3833) stays separate.

## Not covered

- Free text supplied by the bank (payment references, descriptions) can itself contain an IBAN; that cannot be detected reliably.
- Notes already stored by Akahu before this change are not rewritten, because the account number is mixed into free text users may have edited.
- CoinSpot stores its raw deposit/withdrawal record in extra; no account number was confirmed there, and identifier-named keys would be masked anyway.

## Tests

- New tests: `IdentifierMask`, helper short-input boundary, extras masking (incl. nested values and look-alike keys), generated names per provider, both data migrations, Akahu notes, Mercury notes, IBKR report parser.
- Full suite on the branch merged with current `main`: 12460 runs, 0 failures, 0 errors.
- RuboCop, erb_lint and Brakeman clean. No JavaScript changes.
