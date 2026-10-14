Related to #1295 (the rule prompt showing up inconsistently).

Before: after changing a transaction's category in the transaction drawer, the "Updated to … You can create a rule" prompt rendered behind the drawer, where it could not be seen or clicked. When the account sync started by the edit finished a moment later, its page refresh removed the prompt before the user could act on it.

After: the prompt appears as soon as the drawer or modal closes and stays until the user acts on it or closes it. A sync that finishes in the meantime no longer wipes it, and the sync toast still offers its manual **Refresh** button.

The drawer is a native `<dialog>` opened with `showModal()`, so the browser draws it in the top layer, above the notification tray whatever its `z-index`. Separately, `Account::SyncCompleteEvent#broadcast` sends a raw `<turbo-stream action="refresh">`, which Turbo handles itself, so the sync toast controller's existing dialog-aware deferral never sees it.

**How**
- `notification_tray_controller.js`: a `turbo:before-stream-render` listener holds `cta` streams and raw `refresh` streams while any `dialog[open]` exists. A capturing `close` listener on the document, plus a `MutationObserver` while streams are waiting (a dialog removed by a stream fires no `close`), applies them once no dialog is open any more, CTAs first, and skips the refresh while a CTA is still showing. Listening on the document instead of on the one open dialog also covers a drawer that is replaced by the next one in the same frame (removed without a `close` event) and stacked dialogs.
- `sync_toast_controller.js`: the timed auto-refresh gets a matching `#ctaPending()` guard next to the existing mid-form and open-dialog guards.
- Trade-off: a refresh skipped because a CTA was showing is not replayed. The next broadcast refreshes as usual, which is how the toast already handles the mid-form case.
- Scope: the deferral lives in the tray controller, which is attached in the sidebar layouts (app, settings). The rule prompt is only raised by `TransactionsController#update` and `TransactionCategoriesController#update`, whose pages use the app layout.

**Validation**
- New system tests in `test/system/category_rule_prompt_test.rb`: the prompt waits while the drawer is open and shows after it closes; a held prompt survives the drawer being replaced by another transaction's drawer; a held prompt shows when the open dialog is removed without a `close` event. All three fail on `main`.
- `bin/rails test`: 11821 runs, 0 failures, 0 errors.
- `bin/rails test:system`: 241 runs, 0 failures.
- Rubocop, erb_lint, Biome and Brakeman are clean.

**Screenshots** (demo data)

Category changed in the drawer, drawer still open:

| Before | After |
|---|---|
| ![before](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-prompt-drawer/before-drawer-open.png) | ![after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-prompt-drawer/after-drawer-open.png) |

After closing the drawer, the prompt shows on top:

![after closing](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-prompt-drawer/after-drawer-closed.png)

The sync half of the fix can't be shown in a still image, since system tests have no live sync broadcast.
