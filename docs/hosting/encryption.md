# Encryption key rotation (self-hosted)

If your `SECRET_KEY_BASE` is a publicly known value (a default or
placeholder from this project's example files or hosting guides; the boot
log warns about this explicitly), or your Active Record Encryption keys
leaked for any other reason, the keys must be rotated. Data already encrypted under the old keys has to stay readable
while it moves to the new ones, so the old keys are given to the backfill
task as a `previous` scheme
([Rails key rotation](https://guides.rubyonrails.org/active_record_encryption.html#key-rotation))
for that one command only.

Take a database backup before starting and stop the app (web and worker)
for the duration. Docker users: the same steps with `docker compose`
commands are in the [Docker guide](docker.md#upgrading-an-install-that-is-already-running-keep-your-secret_key_base).

## Before you start: find the values in use

You need the `SECRET_KEY_BASE` your data was encrypted with, and the three
Active Record encryption keys if you set them. They are in your `.env`
(`SECRET_KEY_BASE`, `ACTIVE_RECORD_ENCRYPTION_*`), in your Rails
credentials if you configured them there (Rails uses the top-level
`secret_key_base` when the environment variable is not set, and the keys
in the `active_record_encryption` block), or, for an install that never
set `SECRET_KEY_BASE`, in the default of the `compose.yml` it was started
with. If that file was already
replaced, read the value from the old container instead. This works without
a Compose file and also while the container is stopped:

```sh
docker ps -a --filter "name=web" --format "{{.Names}}"   # find the web container
read -r WEB_CONTAINER   # paste its name
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$WEB_CONTAINER" | grep '^SECRET_KEY_BASE='
```

`docker compose exec web printenv SECRET_KEY_BASE` does not help here: it
reads the new `compose.yml` first and stops with the same "Set
SECRET_KEY_BASE" error.

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
it once step 2 has run (see [Settings secrets](#settings-secrets)). Once the
steps above are done, it is safe to change it. Stop the app again and take a
fresh database backup first: the app has been running since step 3, and a
later rollback to the first backup would lose what was written in between.
If `SECRET_KEY_BASE` changed before the settings were converted, pass the old
value in `OLD_SECRET_KEY_BASE` to the backfill command of step 2 as well:

```sh
read -rs OLD_SECRET_KEY_BASE && export OLD_SECRET_KEY_BASE
bin/rails "security:backfill_encryption[100,1]"     # dry run
bin/rails "security:backfill_encryption[100,0]"     # writes
unset OLD_SECRET_KEY_BASE
```

Re-enter any key the task lists under `settings_secrets.not_decryptable`. Then start the
app (web and worker) and check a login and a provider sync.

Re-encrypting does not revoke anything. If the old key was publicly known
or leaked in any other way, and someone else may have had a copy of the
database or a backup, they can
decrypt what was stored with it. In that case also issue new provider API
keys and tokens at each provider (the keys on the self-hosting settings
page and those of connected accounts), even if the tasks above decrypted
them without errors, and revoke the old ones.

## What a new `SECRET_KEY_BASE` invalidates

Data in the database is covered by the steps above, including blocked SSO
identities of removed users. One exception: blocks created while the
install had no Active Record encryption keys at all are stored only as a
digest keyed by `SECRET_KEY_BASE`, and they stop matching once it changes.
Before changing it, note the entries under removed SSO identities on the
instance users page; a removed user who signs in again via SSO afterwards
has to be removed again.

These signed values are not stored and simply stop working:

- Every session: everyone has to sign in again.
- Password reset and email confirmation links that were already sent.
- Subscribed bill calendar links. Copy the link again from the bills
  calendar page and update the subscription.
- Connection flows that were in progress, such as a pending Wise login.

## Rolling back

If a step fails and you cannot fix the listed rows, go back to the state
before the rotation:

1. Stop the app (web and worker).
2. Restore the latest backup taken before the failing step: the one from
   before step 1, or the one from before step 4. Everything written after
   that backup is lost, so roll back as early as possible.
3. Put back the keys that match that backup, and unset every
   `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_*` variable and `OLD_SECRET_KEY_BASE`:
   - Backup from before step 1: the old `SECRET_KEY_BASE`, and the old
     `ACTIVE_RECORD_ENCRYPTION_*` values if you had set any (remove the new
     ones otherwise).
   - Backup from before step 4: the old `SECRET_KEY_BASE` only. Keep the
     new `ACTIVE_RECORD_ENCRYPTION_*` values: the data in this backup is
     already encrypted with them.
4. Start the app and check a login and a provider sync.

Do not roll back by only putting the old keys back without the backup: rows
the write pass already moved are encrypted with the new keys and would no
longer decrypt.

## Settings secrets

API keys and tokens saved on the settings pages (AI, market data and
property valuation keys, and similar) are encrypted with
Active Record Encryption once `security:backfill_encryption` has converted
them. Before that run, existing values keep their old form: encrypted with a
key derived from `SECRET_KEY_BASE`, or plaintext if they were saved before
that encryption existed. The app
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
name under `settings_secrets.not_decryptable`; they do not fail the run, and
a later run with the old key still converts them. After a write pass
without failures, new values are written with
Active Record Encryption too. A fresh install without saved API keys
does that from the start.

Releases before this change cannot read the new form. Before going back to
one, write the old form again with the app stopped:

```sh
bin/rails "security:downgrade_setting_secrets[1]"   # dry run
bin/rails "security:downgrade_setting_secrets[0]"   # writes
```

`security:rotate_setting_secrets` still re-encrypts values in the old form
after a `SECRET_KEY_BASE` change; it leaves converted values alone.
