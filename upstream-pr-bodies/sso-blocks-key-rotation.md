Closes #3233

Most of #3233 already landed with #3190, #3221 and #4936 (`docs/hosting/encryption.md`, `security:backfill_encryption` with the `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_*` variables, `security:rotate_setting_secrets`). This PR closes the remaining gaps.

## Problem

1. **A key rotation silently lifts SSO identity blocks.** When a super admin permanently removes a user, `SsoIdentityBlock` stores an HMAC of the IdP subject id, keyed with `Rails.application.key_generator`, which is derived from `SECRET_KEY_BASE`. The rotation guide tells operators to change `SECRET_KEY_BASE`. After that, no stored digest matches, so every block is gone and a removed user can sign in or be re-created via SSO again (web callback, account linking/JIT, mobile SSO). The subject id itself is not stored, so the digests cannot be recomputed. Reproduced on `main` with a test that stubs a new key generator.
2. **Only one public `SECRET_KEY_BASE` is detected.** `KNOWN_COMPROMISED_SECRET_KEY_BASES` only knew the old compose default. These are just as public and trigger no warning: `secret-value` from `.env.example`, the literal `$(openssl rand -hex 64)` that the Hetzner guide writes into `.env` (Compose does not run it), and the placeholders in the Docker, PetHost and Helm guides.
3. **The rotation guide was missing** how to find the old value once `compose.yml` has been replaced, what a new `SECRET_KEY_BASE` invalidates, and how to roll back.

## Changes

- `SsoIdentityBlock`: new blocks store the subject id with Active Record encryption (`encrypts :uid, deterministic: true`). The rotation backfill re-encrypts it like every other column, so blocks no longer depend on `SECRET_KEY_BASE`. Without Active Record encryption the model keeps writing digests as before.
- Migration `MoveSsoIdentityBlocksToActiveRecordEncryption` adds `uid` (unique per provider) and `legacy_digest_key`. Every existing digest row gets the HMAC key it was made with, stored encrypted, so legacy blocks keep matching after a `SECRET_KEY_BASE` change. `down` restores digests for new rows. It raises `IrreversibleMigration` instead of lifting blocks when `SECRET_KEY_BASE` changed since `up` or the encryption keys are missing.
- Lookup: the encrypted uid first, then legacy digests, with one decryption of the shared stored key. An unreadable stored key is logged and skipped, so it cannot turn every SSO login into a 500.
- `BACKFILL_MANIFEST`: `sso_identity_blocks` now also covers `uid` and `legacy_digest_key`. `CURRENT_BACKFILL_VERSION` goes from 10 to 11 with its digest.
- `KNOWN_COMPROMISED_SECRET_KEY_BASES`: five more public values. The boot warnings and the settings warning (en, id, zh-CN) now say "publicly known value" instead of "compose default".
- `docs/hosting/encryption.md`: finding the old value with `docker inspect` (works without a Compose file and on a stopped container, unlike `docker compose exec ... printenv`), what a new `SECRET_KEY_BASE` invalidates (sessions, reset and confirmation links, bill calendar links, connection flows in progress), and a rollback section.

## Design note

The subject id is now stored encrypted (recoverable with the Active Record keys, like emails and tokens) instead of as a one-way digest. A keyed digest would need a key of its own, and any key derived from `SECRET_KEY_BASE` breaks on rotation. Keeping everything on Active Record encryption means one key set, one rotation path and one backfill.

## Notes for reviewers

- Bumping `CURRENT_BACKFILL_VERSION` turns the plaintext fallback back on for installs that already completed a backfill, until they rerun `bin/rails security:backfill_encryption`. The manifest-digest test requires the bump. #3833 also bumps the version, so whichever PR lands second takes the next number.
- Known limitations: digest rows written while Active Record encryption is not configured still depend on `SECRET_KEY_BASE`, as before. While `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_*` are set, Rails writes and queries deterministic attributes with the oldest scheme, so encrypted lookups (emails, and now blocks) miss rows the backfill already moved. The guide and the boot log already say to unset them before starting the app.
- #3787 also edits `docs/hosting/docker.md`. This PR only changes one sentence there.

## Validation

- New tests: model (encrypted path, legacy rows with and without a stored key, survival of a `SECRET_KEY_BASE` change, unreadable stored key, path without encryption), migration (`up` keeps legacy blocks across a key change, `down` keeps new blocks, `down` refuses after a key change, `down`/`up` restores the schema), detection of the public values. The rotation tests fail on `main`.
- Related suites green: SSO blocks, migration, encryption config, backfill, admin, sessions, OIDC accounts, API auth, OIDC identity, security settings.
- Full suite green apart from environment-only AI/proxy tests. Rubocop clean, Brakeman without warnings.
- Every place that checks a block goes through `SsoIdentityBlock.blocked?` / `find_block`: web SSO callback, account linking/JIT, mobile SSO, identity creation, removal, demo refresh. Admin unblock and the backfill were checked as well.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
