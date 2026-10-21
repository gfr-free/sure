## Summary

Before: Several providers still showed full bank or brokerage account numbers and IBANs. Setup screens printed them (Indexa Capital, Fio, Interactive Brokers, Trade Republic, Trading 212, Akahu). Questrade, Indexa Capital, Fio, Interactive Brokers, Trade Republic and Trading 212 built them into default account names such as "TFSA (12345678)", so the full number reached account lists, reports, CSV exports, the API and the assistant. Transaction "Additional details" dumped counterparty IBANs and account numbers as raw JSON (Monobank, Fio, Akahu), Akahu wrote the counterparty account into every transaction's notes, and Mercury wrote its `details` object (counterparty account and routing numbers, IBAN) into notes as a Ruby hash string.

After: Every one of those places shows only the last 4 characters, e.g. `•••5678`. Existing account names that still contain the full number are rewritten by a data migration; anything a user wrote around the number is kept.

This is the follow-up to the shared `mask_last4` helper (#3826). It implements the remaining items of that privacy series (Indexa, Questrade, Monobank) plus the reuse candidates and boundary note from the maintainer's audit comment on #3826, extended by a provider-by-provider audit of all 25 sync integrations.

## Changes

- **`IdentifierMask`** (`app/models/identifier_mask.rb`): one masking rule for helpers and models. `ApplicationHelper#mask_last4` delegates to it. Sophtron (keeps its stored `****1234` format) and the Trade Republic connection card (strip spaces, hide values under 4 characters) reuse it with their own options.
- **Setup and linking screens** use `mask_last4`: Enable Banking, Lunch Flow, Indexa Capital, Plaid (incl. the duplicate warning), Akahu, Fio (3 views + settings panel, bank code kept), Interactive Brokers, Trade Republic, Trading 212.
- **Generated account names** use the masked number: Questrade, Indexa Capital, Fio, Interactive Brokers (`IbkrAccount.default_name`, also used by the Flex report parser that previously named the record after the bare id), Trade Republic, Trading 212.
- **Data migration** `MaskAccountNumbersInGeneratedAccountNames`: replaces the exact full number wherever it appears on its own in a provider record's or linked account's name (a longer number that merely contains it is left alone), and gives an IBKR provider record named after the bare number the default name. Renamed accounts without the number are untouched. It works in batches of 500 provider rows, joined to their linked accounts.
- **Additional details**: `IdentifierMask.mask_identifiers` masks every value under identifier-like keys (`iban`, `counter_iban`, `counter_edrpou`, `counter_account`, `other_account`, `account_number`, `routingNumber`, `sort_code`, `card_number`, `pan`, ...), matched on the key's final words so `counter_account_name`, `counter_account_type` or `account_number_last_4` stay readable. Inside an object stored under such a key, descriptive fields (`name`, `brand`, `type`, `currency`, `last4`, ...) stay readable and every other value is masked at any depth, so `{"card_number" => {"brand" => "visa", "number" => ...}}` keeps the brand. Applies to the raw dump and to SimpleFIN/Plaid structured rows. Fio's `<account>/<bank>` keeps the bank code.
- **Akahu**: `AkahuAccount#masked_account_number` (dashes dropped before masking) is used by the setup views; notes keep only the last 4 digits of the counterparty account. **Mercury** notes only keep `details` when it is a plain string.
- **Data migration** `RemoveMercuryRoutingDetailsFromNotes`: removes the trailing `details` hash (only when it starts with one of Mercury's details keys) from Mercury notes already stored and keeps the note in front of it. Notes the user edited (locked), or that change while the migration runs, are skipped. The details stay in the raw transactions payload.
- **Data migration** `MaskAkahuOtherAccountInNotes`: masks the counterparty account in Akahu notes already stored. The number is taken from the transaction's stored Akahu metadata and only replaced where it ends the notes, as the importer wrote it; other parts (reference, particulars, code) and the label in any language stay as they are. Locked notes are skipped.
- **Indexa Capital**: stops reading and writing the duplicate `account_number` column (same value as `indexa_capital_account_id`, which every lookup already uses) via `ignored_columns`. The column itself stays, so workers on the previous release can still write it during a rolling deploy; a later release can drop it. The invalid-number error message is masked too.
- **Boundary documented and tested**: values of 4 characters or fewer are shown in full (`mask_last4("123")` is `•••123`), so the helper is for identifiers only, never for secrets.

Deliberately unchanged, as the audit comment recommended: wallet address abbreviations, secret placeholders and the mobile money masker follow their own rules.

## Screenshots

Indexa Capital setup (name and number):

![Indexa setup before/after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/identifier-masking/indexa-setup.png)

Transaction "Additional details" (Fio and Monobank counterparty, demo data):

![Additional details before/after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/identifier-masking/transaction-details.png)

## Effects on other processes

- **Balances, syncs, matching:** none. Only display strings, generated names and Mercury notes change; lookups use the provider id columns, which keep the full value.
- **Account names:** existing default names change once (migration), so exports, reports and API output show the masked form afterwards. Providers that rebuild names on sync (Questrade, Trade Republic) now produce the masked form.
- **Mercury and Akahu notes:** existing unlocked notes lose the details hash (Mercury) or show the counterparty account masked (Akahu) once (migrations); later syncs keep them that way.
- **Rules:** rules match accounts by id, not by name, so they are unaffected.
- **Related:** DebugLogEntry encryption (#3833) stays separate.

## Not covered

- Free text supplied by the bank (payment references, descriptions) can itself contain an IBAN; that cannot be detected reliably.
- Transaction names copied from an account name before this change (e.g. "Transfer to TFSA (12345678)") keep the full number; rewriting transaction names is left for a separate change. New transfers use the masked account name.
- CoinSpot stores its raw deposit/withdrawal record in extra; no account number was confirmed there, and identifier-named keys would be masked anyway.

## Tests

- New tests: `IdentifierMask`, helper short-input boundary, extras masking (incl. nested values and look-alike keys), generated names per provider, all three data migrations, Akahu notes, Mercury notes, IBKR report parser.
- Full suite on the branch merged with current `main`: 12531 runs, 0 failures, 0 errors.
- RuboCop, erb_lint and Brakeman clean. No JavaScript changes.
