## Problem

In the holding drawer, **Unlock** (when the cost basis is locked) and **Reset to provider** (when the security was remapped) are meant to ask for confirmation first. Both `button_to` calls set `data-turbo-confirm`, but their forms also set `data-turbo="false"`. Turbo only shows the confirmation for submissions it handles, so the browser posts the form directly and the action runs on the first click:

- **Unlock** immediately removes the manual cost basis lock, so the next sync or trade calculation can overwrite a hand-entered cost basis.
- **Reset to provider** immediately moves the holding and every trade on the remapped security back to the provider's security.

The confirmations also had no `confirmText`, so the dialog button always read the hard-coded English "Confirm".

This is the same issue #4184 fixed for the cost basis form.

## Change

`app/views/holdings/show.html.erb`, both buttons:

- `form: { data: { turbo: false } }` becomes `form: { data: { turbo_frame: "_top" } }`. The submission now goes through Turbo, so the confirmation shows. The response still replaces the whole page, so the drawer closes and the account page shows the flash, as before. Same pattern as the cost basis form since #4184.
- The confirmation is built with `CustomConfirm.new(...).to_data_attribute`, so the button label comes from `shared.custom_confirm.default_btn_text` in the user's language.

Controllers are unchanged: `reset_security` already answers Turbo requests with a turbo_stream redirect, and Turbo follows the `unlock_cost_basis` redirect to the account page. What the actions do is unchanged; they now just wait for confirmation.

## Tests

New `test/system/holding_drawer_actions_test.rb`: for each button, cancelling leaves the holding unchanged and keeps the drawer usable, and confirming runs the action and shows the success flash. Both tests fail on `main` (no dialog appears and the action runs immediately) and pass with this change.

## Screenshots

Clicking **Unlock**, before (the action already ran, the page shows "Cost basis unlocked") and after (confirmation dialog with a translated button):

| Before | After |
|---|---|
| ![before](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/holding-drawer-confirm/vorher-klick-entsperren.png) | ![after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/holding-drawer-confirm/nachher-klick-entsperren.png) |

## Validation

- `bin/rails test`: 0 failures, 0 errors
- System tests `holding_drawer_actions_test.rb`, `holding_cost_basis_test.rb`, `trades_test.rb`: 0 failures
- Rubocop, ERB lint, Brakeman: clean. No JavaScript changes.
