Before: On a phone (narrower than 640px) in the dark theme, tapping a security search field (new buy/sell trade, "change security" on a holding, convert to trade) opens a full-screen search dialog. Its label was dark text on a dark background, the input was a bright white box with white typed text, and once results appeared the highlighted result was a light gray row with white text. A white line also showed below the result list.

After: The dialog, label, input and result highlight use the design-system tokens and follow the active theme. The light theme looks the same as before.

## Cause

Below its `mobile_at` breakpoint (640px by default) hotwire_combobox opens a full-screen `<dialog>`. The gem paints it with fixed light colors (`--hw-dialog-label-color: #1D1D1D`, `--hw-active-bg-color: #F3F4F6`, `--hw-option-bg-color: #FFFFFF`, default white input). The existing `.combobox` overrides in `app/assets/tailwind/application.css` only cover the inline field and dropdown, not the dialog or these variables. Desktop is not affected by the dialog part.

## How

In the existing `.combobox` block of `app/assets/tailwind/application.css`:

- `.hw-combobox__dialog`, `.hw-combobox__dialog__label` and `.hw-combobox__dialog__input` get `bg-container`, `text-primary` and `border-primary`.
- `--hw-active-bg-color` and `--hw-option-bg-color` point at `--color-container-inset-hover` and `--color-container`. These variables also drive the desktop dropdown, which gets a readable highlight in the dark theme too; in the light theme the highlight gray moves from `#F3F4F6` to the token's `#F0F0F0`.

No raw colors, no JS or ERB changes.

## Screenshots

Phone width (400×850), demo data. From left: light before, light after, dark before, dark after.

Search dialog when opened:

![Search dialog before/after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/combobox-dark-mobile/vorher-nachher.png)

With results, first result highlighted:

![Result list before/after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/combobox-dark-mobile/vorher-nachher-liste.png)

## Impact

Display only. Balances, reports, syncs, imports, the API and jobs are unchanged. No migration. Applies to every hotwire_combobox in the app.

## Tests

- New system test `test/system/combobox_mobile_dialog_test.rb`: dark theme, 400×850 viewport, opens the trade form's security search (provider search stubbed with fixture securities) and compares the computed colors of the dialog, label, input, highlighted result and plain result with the design-system tokens. It fails without the CSS change and passes with it.
- `dark_theme_test`, `trades_test`, `convert_to_trade_test` and `transaction_category_select_test` system tests pass; `bin/rails test` green (11821 runs, 0 failures).
- Rubocop clean, Brakeman 0 warnings, `npm run lint` clean.
