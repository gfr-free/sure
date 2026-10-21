## Problem

Since the cost basis editor rework (#4184), saving over an existing cost basis first asks "Overwrite cost basis?". The confirmation data only carries `title` and `body`. Without `confirmText`, `confirm_dialog_controller.js` falls back to its hard-coded English `"Confirm"`, so the button reads "Confirm" in every locale, e.g. a German title and body with an English button.

## Fix

`app/views/holdings/_cost_basis_form.html.erb` now builds the confirmation with `CustomConfirm.new(title:, body:).to_data_attribute`, the pattern used elsewhere in the app. This adds the translated `shared.custom_confirm.default_btn_text` (already available in 15 locales) and the explicit `primary` variant, which was already the dialog's default. The partial serves both the holding drawer and the holdings-list popover editor, so both are fixed.

Only the button label changes. Title, body, variant and the submit flow stay the same. No new locale keys, no JavaScript changes, no effect on balances, syncs or jobs.

## Screenshots (German locale, demo data)

| Before | After |
| --- | --- |
| ![before](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/cost-basis-confirm-label/vorher.png) | ![after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/cost-basis-confirm-label/nachher.png) |

## Validation

- New controller test renders the editor for a German user and asserts that the confirmation's `confirmText` is the translated default. It fails on main (`nil`) and passes with this change.
- Full `bin/rails test` and `test/system/holding_cost_basis_test.rb` pass.
- Rubocop, ERB lint and Brakeman are clean.

## Out of scope

The holding drawer's "Unlock cost basis" and "Reset security to provider" buttons also pass a hash `turbo_confirm` without `confirmText`, but their forms set `data-turbo="false"`, so Turbo never shows those dialogs and the action runs immediately. That is a separate bug and is left for its own PR.
