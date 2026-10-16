# Reply for upstream PR 4215, jjmata's review comment (2026-10-15 01:23), Plaid pending_transaction_id path

No code change. Post as a PR comment replying to jjmata. First check whether gfr-free already answered; if so, skip.
Other items on 4215: CodeRabbit outside-diff entry.rb:268 fixed in f94ad33 (CodeRabbit confirmed); CodeRabbit major on provider_import_adapter.rb:838-866 declined, CodeRabbit withdrew. Nothing open there.

---

@jjmata Thanks for the review. On the `pending_transaction_id` path: I'd leave it as is in this PR. That claim is unchanged from main and isn't a heuristic, the provider tells us which pending became which booking, so there's no ambiguity to resolve, which is what this PR is about. Whether a booking should still take over a pending the user excluded or edited by hand is a fair question, but it's a separate behavior change for Plaid-style providers with its own trade-offs (the booking would then show up next to the excluded pending), so I'd rather handle it in a follow-up if it comes up.
