Reply to jjmata (issuecomment-6182278189) on upstream PR 4216

Status: posted 15.10. after upstream CI was green on 29f96567d (8/8): https://github.com/we-promise/sure/pull/4216#issuecomment-6184771204

---

Thanks, good catch. Fixed in 29f96567d.

Rather than only guarding `TransferMatchesController`, the check now lives in `Transfer` itself: a new validation rejects a transfer whose inflow is already the outflow of another transfer, or whose outflow is already the inflow of another one. It reports `:taken` on the same attributes as the existing uniqueness validations, so the auto-matcher, the Trade Republic importer and the other callers that already handle those errors cover the cross-role case too.

In the controller, both match methods now end in the friendly "One of these transactions is already part of another transfer." notice instead of the raw validation text. With "create new transaction", nothing is created: validation fails before the new entry is saved.

Tests:
- `TransferTest`: both cross-role directions are invalid; an existing transfer stays valid.
- `TransferMatchesControllerTest`: matching the inflow of an existing transfer as an outflow (via "existing" and via "new") redirects with the notice and creates no transfer or entry. The existing same-role test now asserts the same notice.

All new tests fail without the change. The full suite, rubocop and brakeman are clean.

One limit: two concurrent requests can still both pass the check, because a unique index can't express the cross-role constraint. The UI and sync paths would have to race on the same transaction with a flipped sign, so I left it at the validation. Happy to add a trigger if you'd rather close that too.
