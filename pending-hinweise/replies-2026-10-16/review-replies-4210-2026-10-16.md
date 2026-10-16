# Reply for upstream PR 4210, jjmata's review comment (2026-10-15 01:23), observer misses attribute removal

Commit c7442aa on claude/project-thread-u8l8rw (pushed 2026-10-16). Post as a PR comment replying to jjmata. First check whether gfr-free already answered; if so, skip.

---

@jjmata Thanks, good point, and it turned out not to be theoretical in the browser: removing `open` from a modal dialog in Chromium closes it without a `close` event, and the held prompt stayed queued. Fixed in c7442aa: while streams are waiting, the observer now also watches the `open` attribute (`attributeFilter: ["open"]`), so dropping the attribute releases them like removing the dialog does. Added a system test that removes the attribute from the open drawer; it fails without the change.
