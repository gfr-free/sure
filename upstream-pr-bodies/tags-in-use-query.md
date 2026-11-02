## Problem

Each row of the tags settings page (`/tags`) ran `tag.transactions.any?` to choose between the deletion dialog (tag in use) and a direct delete: one query per tag.

## Change

- New `Tag.ids_with_transactions(family:, tag_ids:)`, built like `Category.ids_with_transactions`: one query through the family's transactions.
- `TagsController#index` loads it once; `tags/_tag` takes a `has_transactions` flag (default `false`, like `categories/_category`).
- The index renders the rows in a loop with the ruler between them, because a collection render with extra locals also passes them to the strict-locals spacer partial.

## Measured

Development mode, demo data plus 30 tags; warm, median of 9:

| `/tags` | before | after |
|---|---|---|
| response time | 218 ms | 183 ms (−16 %) |
| SQL queries | 40 | 9 |

## Effects elsewhere

Display only. Same links and buttons as before. No migration, no change to tag deletion itself.

## Tests

- The tags page runs the same number of queries with 1 and 4 extra tags and shows the dialog link only for used tags (on main: 14 vs 17 queries).
- Model test for `ids_with_transactions`, including a tag of another family.
- Full suite, RuboCop, erb_lint and Brakeman pass. No JS changes.
- No screenshots: the page looks the same.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
