# Upstream PR 4201: review replies (fix pushed in 2e9b611)

## r4267363368 (Codex, rack_attack.rb:166, gate the IP budget on a valid session)

Agreed, fixed in 2e9b611. `password_change/ip` now only counts a request when `password_change_user` resolves a valid signed session, so requests with a missing, tampered or stale cookie (which `authenticate_user!` redirects to sign in before any password check) no longer spend the shared per-IP budget. The session lookup is memoized on the request env, so both throttles share one query. The discriminator test now asserts that no-cookie, unsigned-cookie and unknown-session requests produce no IP key; it fails without the fix.

## r4267340781 (CodeRabbit, rack_attack.rb:165-172, same point)

Thanks, same fix as above in 2e9b611 (your suggested condition, with the lookup memoized so it isn't run twice).

## r4267363382 (Codex, rack_attack.rb:155, key by the impersonated password owner)

Agreed, fixed in 2e9b611. The user key now resolves an in-progress impersonation the same way `Current#user` does: if the session has an `active_impersonator_session` that is `in_progress`, the key is the impersonated user, otherwise the session owner. Attempts during an impersonation now share the target's budget with the target's own sessions and with any other impersonator. New test `password change throttle keys an impersonation by the impersonated user` also checks that the key falls back to the session owner once the impersonation is completed; it fails without the fix.

## jjmata (issuecomment-6182174660)

Thanks for tracing both. Both are fixed in 2e9b611: the IP throttle only counts requests with a valid signed session, and the per-user key follows `Current.user`, so during an impersonation it is the impersonated account. Tests cover the no-cookie, unsigned, unknown-session and impersonation (active and completed) cases. I've updated the description.

---

# Updated PR description (replace the "After" and "How" sections)

**After:** At most 10 password-change attempts per minute per IP and per checked user. Only requests with a valid signed session count, since others are redirected to sign in before any password check. The user is the one whose password is checked (the impersonated user during an impersonation, like `Current.user`), so rotating IPs, holding several sessions or impersonating does not buy extra guesses. Viewing the form, password resets and requests without a valid signed session are not affected.

## How
- Two throttles, `password_change/ip` and `password_change/user`, matching PATCH/PUT `/password` (with the optional format suffix, via the existing `credential_guess_path` helper). `Rack::MethodOverride` runs before Rack::Attack, so the form's `_method=patch` already arrives as PATCH.
- The user key comes from the signed session cookie: one primary-key lookup on `sessions`, plus one on `impersonation_sessions` only while an impersonation is attached. It runs only for those requests and is memoized on the request so both throttles share it. Rack::Attack runs inside `ActionDispatch::Executor`, so the connection is returned as usual.
- The IP throttle only counts requests that resolve a valid session, so unauthenticated traffic from a shared IP cannot lock signed-in users out.

## Tests
- Discriminator test: PATCH/PUT and format suffix match; two sessions of one user share a key; other users get their own; GET edit, password reset, POST produce no key; missing cookie, unsigned cookie and unknown session produce neither an IP nor a user key.
- Impersonation: an in-progress impersonation keys by the impersonated user; after it completes, by the session owner.
- End to end through the middleware stack: one session rotating IPs is blocked on the 11th attempt; two sessions of the same user together are blocked on the 11th attempt. Clock frozen against minute-window flakes.
- `bin/rails test` green; rubocop, erb_lint and brakeman clean.
