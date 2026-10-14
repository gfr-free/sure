**Before:** after a password change, the mobile app and any OAuth client (including MCP connections) that signed in with the old password kept working. Their access and refresh tokens stayed valid for up to 30 days and could keep renewing, so someone who learned the old password and signed in on a phone stayed signed in after the owner changed it. When an admin set a new password for a user on the instance users page, that user's web sessions also stayed signed in.

**After:** every password change (Settings, reset by email, admin, console) revokes the user's Doorkeeper access tokens and unexchanged authorization grants, so the mobile app and OAuth clients must sign in again with the new password. Web sessions end too: a Settings change keeps only the current session, a reset ends all of them, and an admin change ends the target's sessions while keeping the acting admin's own session. A sign-in that checked the old password just before the change cannot finish afterwards (web, API, MFA step, SSO account link). API keys are not touched.

### Relation to #1941

#1941 (open) also ends web sessions on a self-service change and on a reset. After review feedback, this PR now covers those two paths as well, so it overlaps #1941 in `PasswordsController#update` and `PasswordResetsController#update`.

### How

- `User` gets `after_update :revoke_oauth_access, if: :saved_change_to_password_digest?`. It runs inside the update's transaction: `/api/v1/auth/refresh` and `MobileDevice#issue_token!` lock the same user row via `with_active_lock!`, so a refresh racing the password change either finishes first (and its new token is revoked) or waits and then finds the old token revoked.
- Doorkeeper's own `/oauth/token` refresh grant locks only the old token, not the user. The same method therefore also runs in `after_update_commit` as a second sweep: a refresh that already held the old token's lock has committed its replacement by then, and any later refresh finds the old token revoked.
- The two revocation queries are shared with the existing deactivation path (`revoke_all_access_tokens`) through `revoke_doorkeeper_tokens_and_grants`.
- API keys stay valid: they are created deliberately for integrations and do not depend on the password.
- `Admin::UsersController#update` destroys the target's web sessions after a password change, except `Current.session`. `PasswordsController#update` destroys the user's other sessions; `PasswordResetsController#update` destroys all of them.
- Password logins take a SHA-256 fingerprint of the digest they checked (right after `authenticate`) and pass it to `User#with_active_lock!`, which raises `User::StaleCredentialsError` under the row lock if the password changed since. This covers `/api/v1/auth/login`, `/api/v1/auth/sso_link`, the web login, the OIDC account link and the MFA step (fingerprint kept in the session next to `mfa_user_id`).

### Paths that change a password

| Path | Tokens/grants revoked | Web sessions | Test |
|---|---|---|---|
| Settings > change password | yes (model callback) | other sessions end, current stays | controller tests |
| Reset by email | yes (model callback) | all sessions end | controller tests |
| Admin sets password | yes (model callback) | yes, except the acting admin's own session | 3 controller tests |
| Mobile refresh `/api/v1/auth/refresh` after the change | old refresh token rejected (401) | n/a | API test |
| Doorkeeper `/oauth/token` refresh racing the change | second sweep after commit | n/a | model test |
| Login/MFA that checked the old password before the change | no new token | no new session | API, MFA and model tests |
| Console / rake | yes (model callback) | no | model test |

### Impact

- After a password change, users are signed out of the mobile app on all devices and of other browsers, and sign in again.
- MCP and other OAuth clients re-authorize after a password change. API keys and the env-token MCP auth are not affected.
- No migration, no UI change, no change to balances, syncs, reports or jobs.

### Tests

- `test/models/user_test.rb`: tokens and grants revoked, API keys and other users' tokens kept; no revocation without a password change; a token committed after the in-transaction sweep is revoked by the second sweep.
- `test/controllers/passwords_controller_test.rb`, `test/controllers/password_resets_controller_test.rb`: the Settings change and the reset revoke tokens and end web sessions (Settings keeps the current one).
- `test/controllers/api/v1/auth_controller_test.rb`, `test/controllers/mfa_controller_test.rb`, `test/models/user_test.rb`: a login or MFA step that checked the old password does not finish after the change.
- `test/controllers/api/v1/auth_controller_test.rb`: a refresh token issued before the change is rejected.
- `test/controllers/admin/users_controller_test.rb`: admin password change ends the target's sessions, keeps the acting admin's session, and leaves sessions alone without a password change.

The new revocation and sign-out tests fail on `main` and pass with this change. `bin/rails test`, RuboCop, erb_lint, Biome and Brakeman pass.
