# Reply for upstream PR 4203, jjmata's review comment (2026-10-15 01:21), minor nit on rescue NoMethodError

Commit d24895a on claude/project-thread-h6sq9h (pushed 2026-10-16). Post as a PR comment replying to jjmata. First check whether gfr-free already answered; if so, skip.

---

@jjmata Thanks for the thorough pass. I took the nit: in d24895a the export, import and family document checks now rescue `NoMethodError` as well, like `transaction_attachment_authorized?`, so a broken record chain fails closed with a 404 instead of a 500. No new test, since as you traced, `Current.user` is always set on these controllers and I couldn't build a fixture that reaches the rescue without stubbing. PR 4205 carries a copy of `family_export_attachment_authorized?` and got the same one-line change, so the two stay identical.
