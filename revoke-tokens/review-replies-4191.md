## r4265360071 (app/models/user.rb, re-check the password before issuing a token)

Good catch, fixed in cd46dd0. Password logins now record a SHA-256 fingerprint of the digest they checked and pass it into `User#with_active_lock!`. Under the user row lock, the fingerprint is compared against the current digest, and `User::StaleCredentialsError` is raised if the password changed in between. `/api/v1/auth/login` and `/api/v1/auth/sso_link` pass it through `MobileDevice#issue_token!` and answer 401 "Invalid email or password". The web login and the OIDC account link pass it through `create_session_for`. Test: `Api::V1::AuthControllerTest#test_should_not_issue_a_token_when_the_password_changes_during_login`, which fails without the fix.

## r4265360079 (app/controllers/admin/users_controller.rb, pending MFA sign-in after an admin reset)

Fixed in cd46dd0 as well. When the password step hands off to MFA, it stores the same fingerprint in the session next to `mfa_user_id`, and `MfaController#complete_mfa_sign_in` hands it to `create_session_for`. If the password changed after the first factor (admin reset, self-service change or reset), completing the TOTP or passkey step no longer creates a session. The SSO entry points into MFA clear any leftover fingerprint, because no password was checked there. Test: `MfaControllerTest#test_verify_code_cannot_create_a_session_after_the_password_changed`, which fails without the fix.

## CodeRabbit on cd46dd0 (app/controllers/api/v1/auth_controller.rb:120, take the fingerprint before the reload)

Right, thanks. Fixed in f9fdc2d: `login` now takes the fingerprint immediately after `authenticate` succeeds and passes that value unchanged through the `active?` reload to `issue_token!`. New test `test_should_not_issue_a_token_when_the_password_changes_before_the_login_reloads_the_user` changes the password inside the reload step and fails without the fix. `sso_link`, the web login and the OIDC link don't reload the user between the password check and taking the fingerprint, so they were not affected.

## jjmata (app/models/user.rb:256, web sessions survive Settings change and reset)

Good point, thanks. Added in d26f540: a Settings password change now ends all of the user's other web sessions and keeps the current one, and an email reset ends all of them. Together with the admin path, every password change now signs out web sessions as well as OAuth/mobile tokens. Tests: `PasswordsControllerTest#test_update_signs_the_user_out_of_their_other_web_sessions_and_keeps_the_current_one` and `PasswordResetsControllerTest#test_update_signs_the_user_out_of_every_web_session`. #1941 covered the same two web-session paths earlier; this PR now includes them, so #1941 would overlap in `PasswordsController#update` and `PasswordResetsController#update`. I've updated the description.
