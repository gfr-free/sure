@jjmata thanks for the design-system pointer. In 20c376c, ec9b721 and bae97dd the split fields now use the same building blocks as the rest of the app:

- **Manual split dialog:** name and amount use `StyledFormBuilder` fields, category uses `DS::Select` (badge variant, searchable), merchant uses `DS::MerchantSelect` and tags use `DS::TagSelect`. The three hand-built picker partials are gone.
- **Split rule rows:** `StyledFormBuilder` fields and selects, plus `DS::TagSelect` for tags, so the tag picker is visible with tag colors instead of a plain multi-select.
- **Compact tag picker:** `DS::TagSelect` has a new `compact: true` option for dense rows. It keeps the empty and the filled trigger at a plain input's height, so the tag field lines up with the selects next to it. The default stays as it is, so the transaction form is unchanged.
- **DS fixes needed for repeated rows:** `DS::Select` can now scope its label/trigger ids to the field (`scoped_ids: true`), so several rows no longer share ids, and the merchant/tag trigger buttons carry the id their `<label for>` points at.
- **Bug found while testing:** editing the splits of an existing rule was silently not saved (nested-attributes autosave skipped the action because only the virtual `split_rows` changed). Fixed in `Rule::Action#split_rows=`, with a controller test that fails without it.

Before / after, rule form and split dialog:

![Split rule rows before and after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/split-transaction-rule/rule-before-after.png)

![Split dialog before and after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/split-transaction-rule/splits-before-after.png)

New tests: system tests for picking category, merchant and tags in both forms, a system test that the tag field keeps the other pickers' height, and a controller test for unique ids and labelled controls per split row. Locally the full `bin/rails test`, the system tests, rubocop, erb_lint, Biome and Brakeman are green.
