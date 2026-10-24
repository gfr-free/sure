## Problem

On a phone the rules page does not fit the screen:

- A rule with a long name or a long condition or action value (a merchant name, an unbroken payee string) pushes its active toggle and its menu past the right edge. Because the settings pane hides horizontal overflow, the menu cannot be reached at all.
- The chips shrink to the width of their longest word and wrap one word per line into tall ovals.
- On narrow phones the page header does not wrap, so "New rule" is cut off.

Cause: in `app/views/rules/_rule.html.erb` the text column is a flex item with the default `min-width: auto`, so it never gets narrower than its longest word, and the toggle and menu have no reserved space. The rule-order handle takes another 40 px. In `app/views/layouts/settings.html.erb` the page actions are `shrink-0` in a row that never wraps.

## What changes

- **Rule row:** the row is a two-column grid. On a phone the rule name sits on the first row with the active toggle and the menu to its right, as in the tags and merchants lists. The condition, action and date chips span the full width below. Each chip stays on one line and ends in an ellipsis when it is too long, like long merchant names; the full text is in the edit dialog. From the `sm` breakpoint the layout matches the current desktop layout (controls centred on the right); only very long values are shortened there too. A rule without a name shows its toggle and menu alone on the first row on phones.
- **Settings header:** the title row wraps. When the actions do not fit next to the title, they move to their own line and stay right-aligned. When they fit, nothing changes. The title may shrink and break long words. This applies to every settings page with page actions (rules, tags, categories, merchants, API keys, recurring, accounts).

Only CSS classes change; no data, sync, job or report effects.

## Screenshots (demo data)

Rules page at 390 px, before (main) and after:

![rules phone](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rules-mobile-layout/rules-phone-vorher-nachher.png)

Rules page on desktop, before and after (unchanged apart from the long value in the chip):

![rules desktop](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rules-mobile-layout/rules-desktop-vorher-nachher.png)

Tags page at 390 px, where the header already fit (unchanged):

![tags phone](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rules-mobile-layout/tags-phone-vorher-nachher.png)

## Notes for review

- `DS::Pill` (`truncate: true`) was considered for the chips. It would change their look on every screen size (tinted tone, medium weight, tighter line height), so this fix keeps the existing chip markup and only adds `max-w-full truncate`. Moving the chips to `DS::Pill` could be a separate change.
- The layout switch uses the viewport `sm:` breakpoint like the rest of the settings pages.

## Validation

- New system test `keeps a rule with long text inside a phone-width screen` (320 px viewport). It fails on main (the rule name and the menu run past the row, and "New rule" ends at 345 px in a 320 px viewport) and passes on this branch. It also checks that the menu sits next to the rule name.
- `bin/rails test` and `test/system/rules_test.rb` pass locally.
- RuboCop, ERB lint and Brakeman (0 warnings) are clean. No JavaScript changed.
