**Before:** after a password change, the mobile app and any OAuth client (including MCP connections) that signed in with the old password kept working. Their access and refresh tokens stayed valid for up to 30 days and could keep renewing, so someone who learned the old password and signed in on a phone stayed signed in after the owner changed it. #1941 now ends web sessions on every password change and revokes OAuth tokens on a reset by email, but a change in Settings or by an admin still leaves the mobile app and OAuth clients signed in.

**After:** every password change (Settings, reset by email, admin, console) revokes the user's Doorkeeper access tokens and unexchanged authorization grants, so the mobile app and OAuth clients must sign in again with the new password. A sign-in that checked the old password just before the change cannot finish afterwards (web, API, MFA step, SSO account link). API keys are not touched.

### Relation to #1941

This PR is now rebased in scope on top of #1941. The web-session part it used to carry is gone, because #1941 already ends sessions on all three paths (Settings, reset, admin). What is left is the OAuth/mobile part and the race guard for sign-ins:

- The explicit `@user.revoke_oauth_tokens!` in `PasswordResetsController` is dropped, because the model callback below now does the same on every password change. The callback reuses `User#revoke_oauth_tokens!` from #1941.
- `create_session_for` and `begin_mfa_handoff` from #1941 take an optional `password_fingerprint:`.

### How

- `User` gets `after_update :revoke_oauth_access, if: :saved_change_to_password_digest?`. It runs inside the update's transaction: `/api/v1/auth/refresh` and `MobileDevice#issue_token!` lock the same user row via `with_active_lock!`, so a refresh racing the password change either finishes first (and its new token is revoked) or waits and then finds the old token revoked.
- Doorkeeper's own `/oauth/token` refresh grant locks only the old token, not the user. The same method therefore also runs in `after_update_commit` as a second sweep: a refresh that already held the old token's lock has committed its replacement by then, and any later refresh finds the old token revoked.
- API keys stay valid: they are created deliberately for integrations and do not depend on the password.
- Password logins take a SHA-256 fingerprint of the digest they checked and pass it to `User#with_active_lock!`, which raises `User::StaleCredentialsError` under the row lock if the password changed since. This covers `/api/v1/auth/login`, `/api/v1/auth/sso_link`, the web login, the OIDC account link and the MFA step (`begin_mfa_handoff` keeps the fingerprint next to `mfa_user_id`; first factors without a password check clear it). Without this, a login that checked the old password could mint its session or token right after #1941's sweep and stay signed in.

### Paths that change a password

| Path | Tokens/grants revoked | Web sessions | Test |
|---|---|---|---|
| Settings > change password | yes (model callback, new) | handled by #1941 | controller test |
| Reset by email | yes (model callback; was an explicit call from #1941) | handled by #1941 | existing #1941 tests |
| Admin sets password | yes (model callback, new) | handled by #1941 | controller test |
| Mobile refresh `/api/v1/auth/refresh` after the change | old refresh token rejected (401) | n/a | API test |
| Doorkeeper `/oauth/token` refresh racing the change | second sweep after commit | n/a | model test |
| Login/MFA that checked the old password before the change | no new token | no new session | API, MFA and model tests |
| Console / rake | yes (model callback) | no | model test |

### Impact

- After a password change in Settings or by an admin, users are also signed out of the mobile app on all devices and sign in again.
- MCP and other OAuth clients re-authorize after a password change. API keys and the env-token MCP auth are not affected.
- No migration, no UI change, no change to balances, syncs, reports or jobs.

### Tests

- `test/models/user_test.rb`: tokens and grants revoked, API keys and other users' tokens kept; no revocation without a password change; a token committed after the in-transaction sweep is revoked by the second sweep; `with_active_lock!` rejects a stale fingerprint.
- `test/controllers/passwords_controller_test.rb`, `test/controllers/admin/users_controller_test.rb`: a Settings change and an admin change revoke the user's OAuth tokens.
- `test/controllers/api/v1/auth_controller_test.rb`, `test/controllers/mfa_controller_test.rb`: a login or MFA step that checked the old password does not finish after the change; a refresh token issued before the change is rejected.

The new revocation tests for the Settings and admin paths fail on `main` and pass with this change; #1941's reset test still passes with its explicit call removed. `bin/rails test`, RuboCop and Brakeman pass (no ERB or JS changes).
