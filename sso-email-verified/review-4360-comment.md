Claude review (8a2c1fd)

Thanks for the ping, @jjmata. I went through the whole diff, ran the suite and compared the flows on main and on this branch.

The gate itself looks right to me. Every path that creates an account or redeems an invitation by email now needs a verified email: the link page, `create_user`, the mobile callback and `sso_create_account`. Linking an existing account still needs its password, and token invitations are unaffected. I didn't find a way around it. On main I could reproduce #3825 in the browser: an IdP email with `email_verified: false` accepted a pending admin invitation. On this branch it's blocked, and a verified email still works.

What I ran on 8a2c1fd:
- `bin/rails test`: 12,493 runs, 0 failures, 0 errors (36 skips).
- The new controller tests without the production changes: 8 of 9 fail. The 9th (`create_link still links an existing account when the email is unverified`) is a guard and passes on both, as intended.
- RuboCop, erb_lint and Brakeman are clean, and `rswag:specs:swaggerize` reproduces `docs/api/openapi.yaml` unchanged.

### Overlap with #3994

I agree they're complementary, and the shape you proposed, `email_verified && (invitation.present? || AuthConfig.jit_account_creation_allowed?(email))`, is what I ended up with when I combined them. I merged both into main locally, in both orders:

- The same six files conflict either way: `oidc_accounts_controller.rb`, `sessions_controller.rb`, `docs/api/openapi.yaml`, `spec/requests/api/v1/auth_spec.rb`, and two test files where both PRs add tests at the same spot. All of it is additive. `api/v1/auth_controller.rb` and `oidc.md` merge cleanly.
- After combining, three of #3994's tests need `email_verified: true`. The API tests `should reject SSO create account when self-hosted signups closed after the callback` and `should reject SSO create account when self-hosted signups are invite-only` fail, because their hand-built linking-code payload has no `email_verified`, so they get the new 403 instead of "disabled". `mobile SSO does not offer account creation when self-hosted signups are closed` still passes, but for the wrong reason, since its mock has no `email_verified` either.
- The Invite-only/Closed bullet that #3994 adds to section 3.3 should then say that the invitation needs a verified email (link to 6.7).

#3994 first is fine with me. If it isn't reviewed in time for v0.7.7, please don't hold this one for it: I'll merge main into #3994 and do the above there.

#2504 also touches the same decision points (and the same six files) and adds its own `OidcIdentity.provider_config_for`, so whichever of these lands later should probably share one provider lookup.

### Findings

**1. Severity: medium. `jit_blocked` is never written in the normal flows** (`docs/hosting/oidc.md:467`, `:473`, `:628`)

The upgrade note tells admins to check `SsoAuditLog.by_event("jit_blocked")`, but a blocked user never produces a row. The link page hides the button and the user leaves; the mobile app hides the create tab and never calls `sso_create_account`. I checked it with an integration test on this branch: callback plus link page, 0 rows; mobile start plus callback, 0 rows; a direct `POST /oidc_account/create_user`, 1 row. An admin following the upgrade note gets an empty result and concludes nobody is affected.

I see your point about the GET link page repeating on refresh. Logging in the callback avoids that, since every entry needs a full IdP round trip with state and nonce: in `openid_connect` where `pending_oidc_auth` is stored, and in `handle_mobile_sso_onboarding`, only when the email is present and unverified, no account exists, and an invitation or JIT would otherwise have been offered. If you'd rather keep it where it is, those three doc lines should say it only records direct create requests, and the upgrade note should point to the message users see instead.

**2. Severity: medium. Upgrade path for ENV/YAML providers** (`docs/hosting/oidc.md:471`, `:473`, `config/auth.yml`)

Production loads providers from YAML unless `AUTH_PROVIDERS_SOURCE=db`, so the usual Docker setup with `OIDC_ISSUER` and friends has no way to set the opt-in. `:471` says it's only available for database-backed providers. In fact `provider_config_for` reads `settings` from the YAML list too (the initializer keeps the key, and the `corp_oidc` entry in the model test covers that path), but that means mounting a custom `auth.yml`. Meanwhile some common IdPs don't send `email_verified: true` by default: authentik 2025.10 changed its default email mapping to `false` (listed there as a breaking change), Keycloak sends `false` for users without a verified email, and Entra omits the claim. On those setups both JIT sign-up and invitations by email stop after the upgrade. In YAML mode, flipping the toggle on a provider record in `/admin/sso_providers` saves fine but has no effect.

Suggestion: one more key on the `oidc` entry in `config/auth.yml`,

```yaml
      settings:
        treat_email_as_verified: <%= ENV.fetch("OIDC_TREAT_EMAIL_AS_VERIFIED", "false") %>
```

documented next to the other `OIDC_*` variables and in 5.1, the sentence at `:471` corrected, and an upgrade note that also mentions invitations by email and the ENV/YAML route (or `sso_providers:seed` plus `AUTH_PROVIDERS_SOURCE=db`).

**3. Severity: low. The new toggle has no accessible name** (`app/views/admin/sso_providers/_form.html.erb:209-219`)

`DS::Toggle` labels the checkbox with just `&nbsp;`, so screen readers announce an unnamed switch, and axe reports a `label` violation. Giving the `<p>` at `:211` an `id` and passing `"aria-labelledby": "<that id>"` to `DS::Toggle` fixes it, since its options go to the checkbox. The `enabled` toggle further up has the same gap.

**4. Severity: low. The verified mobile path is no longer tested** (`test/controllers/sessions_controller_test.rb:866-912`)

Before this PR, `mobile SSO redirects with error when OIDC identity not linked` exercised the positive path (creation offered). Its mock has no `email_verified`, so it now runs the blocked path and still passes, because it only checks `cached.key?(:allow_account_creation)`. The API tests seed `email_verified: true` by hand, so nothing ties the callback's write to the API's read: with `email_verified: false,` hard-coded at `sessions_controller.rb:506`, the sessions, auth API, OIDC accounts and model tests all still pass (158 runs). Setting `email_verified: true` in that mock and asserting `params["allow_account_creation"] == "true"` and `cached[:email_verified] == true` would cover it, optionally followed by `sso_create_account` returning 200.

**5. Severity: low. "Click below to create a new account" with nothing below** (`app/views/oidc_accounts/link.html.erb:35-39`)

The info alert is unconditional; only the button depends on `@allow_account_creation`. On main that only happened with `link_only` or a domain list. Now it's what every user of an IdP without the claim sees, invitees included. Showing the info alert only when creation is allowed, and otherwise a `DS::Alert` with `variant: :warning` and the block message, would fix it. The assertions at `test/controllers/oidc_accounts_controller_test.rb:193` and `:521` would need a small update.

Minor: deferring the mobile explanation to a Flutter follow-up sounds right. The server could already add something like `reason=email_not_verified` to the redirect in `handle_mobile_sso_onboarding`. Older apps ignore unknown parameters, so the follow-up would only have to read it.

---
_Generated by [Claude Code](https://claude.ai/code)_
