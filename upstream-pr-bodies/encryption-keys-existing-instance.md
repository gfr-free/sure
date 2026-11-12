Closes #2422

## Problem

Since #3189, a self-hosted instance without its own keys encrypts with keys derived from `SECRET_KEY_BASE`. Rows written before that stay plaintext until `security:backfill_encryption` converts them. Several gaps remain on main:

- **The backfill misses most tables.** It works from a hand-kept list of 20 tables, but 60 tables declare `encrypts`. Kraken, Coinbase and SnapTrade items, API keys, SSO providers, Wise, IBKR and others are missing. A run reports `ok: true` and leaves those rows plaintext.
- **The backfill can destroy data.** With `support_unencrypted_data` on, a value encrypted with keys the instance doesn't have reads back as the raw envelope string, and the task encrypts that string again. The original value is lost. This happens, for example, after adding your own keys to an instance whose data uses the derived ones, which is #2422. Plaintext jsonb objects with a `"p"` key also crash the run with `NoMethodError`, because Rails reads them as envelopes.
- **Keys in `.env` have no effect with Docker.** `compose.example.yml` and `compose.example.ai.yml` don't pass `ACTIVE_RECORD_ENCRYPTION_*` to the containers. The settings that `docs/hosting/encryption.md` and the in-app guide describe never reach the app.
- **No guide covers #2422.** Adding keys to an instance with data changes its keys. Data already encrypted with the derived keys can't be read with new ones and has to be rotated. Data that is still plaintext can be converted directly. Nothing tells an operator which case they are in.

## Changes

- **`security:backfill_encryption`**:
  - Finds every model that declares `encrypts` at runtime instead of using the list.
  - Session columns go through the same path. IP digests run separately as `session_ip_digests` and only touch rows that need one.
  - Refuses values that still hold a complete Rails encryption envelope (string or jsonb object) instead of encrypting them again. This applies to the dry run and the real run.
  - Falls back to the raw value when the getter raises on envelope-like plaintext.
  - Reports a top-level `failed_count`, and returns `ok: false` with exit status 1 when any row fails.
- **Compose examples**: forward the three keys as `${VAR:-}`. An empty value counts as unset, so installs without keys keep the derived ones.
- **Docs** (`docs/hosting/docker.md`, new section "Encrypting sensitive data"):
  - Where the keys come from, and how to set your own on a new instance.
  - Converting rows stored before encryption with the current keys: take a named backup, stop `web` and `worker`, run the dry run, convert with `docker compose run --rm web`, then start and check.
  - Switching an existing instance to your own keys. A dry run with the new keys shows whether any data is encrypted with the old ones. If none is, the data is converted directly. If some is, the guide sends the operator to the rotation procedure in `encryption.md` instead.
  - An undo path via the named backup, recovery steps for operators who already added keys, and a warning for keys that were sitting unused in `.env`.
- `.env.example` and the in-app guide link now point to the new section.

## Related pull requests and merge order

Several open PRs touch the same task, the same files or the same topic:

- #3221 adds a completion flag that turns the plaintext fallback off once the backfill has run. It also adds a manifest of encrypted columns (`BACKFILL_MANIFEST`), with a test that keeps it in sync with the `encrypts` declarations.
- #3190 adds key rotation to the task, including keys derived from a previous `SECRET_KEY_BASE`. It already carries the #3221 manifest.
- #3833 encrypts `DebugLogEntry` metadata and adds it to the backfill.
- #2388 forwards the same three variables in the compose examples. This PR includes that change.
- #3583 adds `SsoProvider` to the old list. Runtime discovery covers it here.
- #2679 and #4887 document the same topic in other places.

#3221, #3190 and #3833 are mine, and I'll bring them up to date in this order:

1. **This PR first.** It is the smallest of the group, adds no migration or setting, and fixes the coverage and double-encryption problems on main today.
2. **#3221 next.** The task loop then switches to its manifest, which the completion flag needs at boot. It keeps the refusal, the raw-value fallback and `failed_count` from this PR. I test-merged the two branches this way, and the encryption tests with keys (445 runs) and the full suite (15654 runs) pass.
3. **#3190 after #3221**, since it builds on the same manifest. Once it is in, the "Switching an existing instance to your own keys" section can point to its rotation task instead of the manual steps in `encryption.md`.
4. **#3833 at any point.** On top of this PR it needs no list entry. After #3221 it needs a manifest entry and a version bump.

If #2388 or #3583 is merged first, it touches the same lines and the conflict is trivial to resolve.

## Tests

- `test/lib/tasks/security_backfill_test.rb` (these fail on main):
  - Checks coverage against every `encrypts` line in `app/models`.
  - Converts a plaintext value in every encrypted column of every table and checks that it is stored as an envelope and decrypts to the original.
  - Checks a rerun, the refusal of foreign ciphertext in string and jsonb columns (including the dry run and the exit status), envelope-like plaintext, and session user agents and IP digests.
- The full `bin/rails test` (15675 runs) and the encryption tests with keys pass. Rubocop, Brakeman and erb_lint are clean.
- End to end, with an image built from this branch and the new compose file, starting from an instance created with the current release and demo data (all plaintext):
  - After the update, new writes such as session user agents are encrypted with the derived keys, and older rows stay plaintext.
  - Converting with the current keys: the dry run lists 61 entries with `failed_count` 0, and the conversion and a rerun report `ok: true`. The database then holds envelopes, and sign-in and the dashboard, transaction, account and provider pages work.
  - Switching to your own keys once data uses the derived keys: the dry run refuses the derived-key session row (`failed_count` 1, exit status 1), and removing the keys again leaves the instance working.
  - Switching to your own keys right after the update, before anything is written with the derived keys: the dry run reports 0, and after the conversion the app runs with the new keys and everything decrypts.
  - The undo path restores the plaintext instance from the named backup.
  - Adding keys without converting reproduces the silent damage: derived-key values read back as raw envelopes.

## Not included

The docs don't describe running the conversion with the app online. With `web` and `worker` stopped, nothing writes while rows change keys.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
