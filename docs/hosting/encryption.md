# Encryption key rotation (self-hosted)

If your `SECRET_KEY_BASE` was ever shipped as a default in this project's
example Compose files (the boot log warns about this explicitly), or your
Active Record Encryption keys leaked for any other reason, the keys must be
rotated. Data already encrypted under the old keys has to stay readable
while it moves to the new ones, so the old keys are given to the backfill
task as a `previous` scheme
([Rails key rotation](https://guides.rubyonrails.org/active_record_encryption.html#key-rotation))
for that one command only.

Take a database backup before starting and stop the app (web and worker)
for the duration. Docker users: the same steps with `docker compose`
commands are in the [Docker guide](docker.md#upgrading-an-install-that-is-already-running-keep-your-secret_key_base).

## 1. Set new keys

Generate a fresh key set and configure it as the current keys via
`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
`ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` and
`ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`:

```sh
bin/rails db:encryption:init
```

Keep `SECRET_KEY_BASE` unchanged for now.

## 2. Re-encrypt under the new keys

Pass the old keys in the environment of the backfill command only:

- Keys auto-derived from `SECRET_KEY_BASE` (no explicit keys were set):
  put that `SECRET_KEY_BASE` value in
  `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE`.
- Explicitly set keys: put the old values in
  `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEY`,
  `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_DETERMINISTIC_KEY` and
  `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_KEY_DERIVATION_SALT`.

```sh
read -rs ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE && export ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE   # keeps it out of your shell history
bin/rails "security:backfill_encryption[100,1]"      # dry run: reports what would change
bin/rails "security:backfill_encryption[100,0]"      # writes
unset ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE
```

The write pass encrypts legacy plaintext rows and re-encrypts every
encrypted column under the new keys, deterministic ones (emails,
`otp_secret`, tokens) included. A value that neither the new nor the old
keys decrypt is not touched and is reported under `failed_samples`. Check
that the task ends with `"ok": true` and `failed_count: 0` for every model;
it exits with status 1 otherwise.

## 3. Start the app without the old keys

Start the app with the `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_*` variables
unset. While they are set, Rails writes deterministically encrypted values
with the old key (it keeps equality lookups stable that way), and the app
logs a warning at boot. Spot-check a login, a provider sync and an MFA
flow.

## 4. Settings and `SECRET_KEY_BASE`

`SECRET_KEY_BASE` itself also signs session cookies; changing it signs
everyone out. API keys and tokens saved in the settings no longer depend on
it once step 2 has run (see [Settings secrets](#settings-secrets)). If
`SECRET_KEY_BASE` changed before the settings were converted, pass the old
value in `OLD_SECRET_KEY_BASE` to the backfill command of step 2 as well:

```sh
read -rs OLD_SECRET_KEY_BASE && export OLD_SECRET_KEY_BASE
bin/rails "security:backfill_encryption[100,1]"     # dry run
bin/rails "security:backfill_encryption[100,0]"     # writes
unset OLD_SECRET_KEY_BASE
```

Re-enter any setting the report lists under `settings_secrets.failed_samples`.

## Settings secrets

API keys and tokens saved on the settings pages (AI, market data and
property valuation keys, Plaid secrets, and similar) are encrypted with
Active Record Encryption once `security:backfill_encryption` has converted
them. Before that run, existing values keep their old form: encrypted with a
key derived from `SECRET_KEY_BASE`, or plaintext for Plaid secrets. The app
reads both forms, so the conversion is optional and can wait for a
convenient maintenance window.

The conversion is part of the normal backfill, with the app stopped:

```sh
bin/rails "security:backfill_encryption[100,1]"     # dry run
bin/rails "security:backfill_encryption[100,0]"     # writes
```

Each value is decrypted, encrypted again, checked to decrypt back to the
same value, and only then written, and only if nobody changed it in the
meantime. Values no configured key opens are left untouched and listed by
name. After a write pass without failures, new values are written with
Active Record Encryption too. A fresh install without any saved settings
does that from the start for the keys on the self-hosting page. Plaid
secrets saved on the bank sync page stay plaintext until the first backfill
run, as on existing installs.

Releases before this change cannot read the new form. Before going back to
one, write the old form again with the app stopped:

```sh
bin/rails "security:downgrade_setting_secrets[1]"   # dry run
bin/rails "security:downgrade_setting_secrets[0]"   # writes
```

`security:rotate_setting_secrets` still re-encrypts values in the old form
after a `SECRET_KEY_BASE` change; it leaves converted values alone.
