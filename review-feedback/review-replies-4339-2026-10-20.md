# Review replies for upstream PR 4339 (round 1, 2026-10-20)

Fix commit: 2ac7cfb9a. Each reply goes on its thread; then resolve the thread. Check first whether gfr-free already replied on a thread; if so, only resolve.

## PRRT_kwDOPRMXr86uRvms (Codex P1, Indexa column drop)

Good catch, thanks. I took the drop out of this PR in 2ac7cfb9a: the migration is gone and the column stays in the schema. The model still ignores it, so the new release neither reads nor writes it, while workers on the previous release can keep writing it during a rolling deploy. The value is the same as `indexa_capital_account_id`, which stays anyway, so keeping the column costs no privacy. Dropping it can follow in a later release.

## PRRT_kwDOPRMXr86uRvm1 (Codex P1, name cleanup vs. legacy importers)

I traced the paths and I'm leaving this as is. Account names (the user-facing `accounts.name`) are only set when a user links an account, which runs in the web process that already has the new release when the migration runs. Provider-record names do get written by workers, but Questrade, Indexa Capital, Interactive Brokers (report parser), Trade Republic and Trading 212 rebuild them on every sync. So if an old worker writes a full number during the cutover, the next sync on the new release writes the masked name again. The only name that would stay is a Fio provider record that an old worker imports for the very first time during the cutover, because Fio keeps an existing name. A second cleanup migration in a later release for that window didn't seem worth its code.

## PRRT_kwDOPRMXr86uRvm- (Codex P2, batch the backfill)

Done in 2ac7cfb9a. The migration now walks each provider table with a keyset cursor in batches of 500 and joins the linked accounts in the same query, so it costs one query per batch plus one UPDATE per name that actually changes. A test runs it with a batch size of 1 across two provider rows.

## PRRT_kwDOPRMXr86uRvnD (Codex P1, masking in TransactionsHelper)

Agreed, done in 2ac7cfb9a. The key matching, the recursive masking and the Fio `<account>/<bank>` rule moved into `IdentifierMask` (`IdentifierMask.mask_identifiers`, `identifier_key?`, `mask_identifier`), with their own unit tests. `TransactionsHelper#build_transaction_extra_details` now just calls `IdentifierMask.mask_identifiers(tx.extra)`.

## PRRT_kwDOPRMXr86uRvnN (Codex P1, Akahu normalization in templates)

Agreed, done in 2ac7cfb9a. `IdentifierMask.last4` takes `strip_dashes: true`, `AkahuAccount#masked_account_number` uses it, and the three Akahu templates render that method. The Akahu notes path uses the same option, so both follow one rule.

## PRRT_kwDOPRMXr86uRyTb (CodeRabbit, restrict DETAILS_HASH)

Done in 2ac7cfb9a. The pattern now only matches a trailing hash whose first key is one of the top-level keys of Mercury's `details` object (`address`, `domesticWireRoutingInfo`, `electronicRoutingInfo`, `internationalWireRoutingInfo`, `debitCardInfo`, `creditCardInfo`). New tests: a note ending in `{"tag" => "tax"}` is kept, and international wire details are removed.

## PRRT_kwDOPRMXr86uRyUK (CodeRabbit, guard the UPDATE)

Done in 2ac7cfb9a as suggested: the UPDATE also requires the notes value that was read and skips rows whose notes got locked in the meantime.
