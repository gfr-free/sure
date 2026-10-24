**Before:** with many rules, the rules page is one long sortable list. There is no search, no filter and no way to section it, so it is hard to see which rules exist and where a rule sits in the run order.

**After:** rules can sit in a named group, the list can be searched and filtered, and groups and single rules can be folded. Groups only arrange the list: rules still run as one list from top to bottom, exactly in the order the page shows.

### How

**Rule groups (overview only)**
- New `rule_groups` table (family, name, position). A rule belongs to at most one group (`rules.rule_group_id`, FK with `on_delete: :nullify`).
- Rules and groups share one position sequence, and a group's rules follow the group directly, so `Rule.ordered` is still the page order. `Rule::Runner`, "stop processing" and "top rule wins per field" are untouched. `Rule::Layout` builds the list and is the only writer of positions; every write takes the existing per-family advisory lock (`Rule.lock_positions!`) first.
- Drag (mouse, touch) or keyboard-move whole groups, rules outside a group, and rules inside their group. A rule changes group in the rule form, not by dragging. The inner list reuses `sortable_list_controller.js` under a second identifier (`sortable-sublist`), because Stimulus does not pass events from inside a nested controller of the same name; each list only handles drags of its own items.
- Group header (`DS::Disclosure`): name, rule count, "N inactive". Menu (`DS::Menu`): turn all rules on or off (rule by rule, so each rule runs its own callbacks, e.g. the email baseline), rename, delete (rules keep their place, without a group).
- Groups and rules outside a group fold to one line. The fold state is kept per browser (`localStorage`) and re-applied after a Turbo morph refresh, so switching a rule does not reopen folded groups.
- Groups are created in the rule form (select, or "new group" field) or with "New group" above the list.
- Adding a classifier rule at the top (`Family#add_classifier_rule!`) moves groups down together with the rules.

**Search and filters**
- Search over the rule name and the labels and values of conditions (including condition groups) and actions, in the browser.
- Filter popover like the transactions filter (`DS::Popover` + tabs): status, action type, condition type, account, group. Only types the family's rules use are offered; accounts only if the user can see them.
- State lives in the URL and is rendered by the server, so a reload keeps it.
- Dragging is off while a search or filter is active (with a hint), and folded groups open to show their matches, so a drop cannot land among hidden rules.

**Import/export**
- Rule CSV export/import and the full data export/import carry the group name. A rule CSV without the group column leaves existing groups as they are; an empty group cell removes the rule from its group.
- "Delete all rules" and the financial data reset also delete the groups (reset count `rule_groups`, documented in `docs/api/openapi.yaml`).

### Release notes

The rules page can now group rules into folders, search them, and filter them by status, action, condition, account and group. Groups only organize the list; rules still run in the order shown.

### Effects on other parts

- **Rule execution, balances, reports:** unchanged. Groups have no state of their own.
- **Migration** (reversible): new table and nullable column. Existing rules keep their positions and stay ungrouped.
- **API v1:** rules JSON is unchanged (groups can follow later). The reset status counts gain `rule_groups`.
- **Shared sortable list:** `sortable_list_controller.js` gains an item selector based on the controller identifier and ignores a drag that started on an item of a nested list. Accounts, dashboard and other lists behave as before (their system tests pass).

### Screenshots

Demo data. Before = `main`, after = this branch.

| Before | After |
|---|---|
| ![before](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-groups/current/before-list.png) | ![after](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-groups/current/after-list.png) |

| Groups and rules folded | Search "rewe" |
|---|---|
| ![folded](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-groups/current/after-overview-folded.png) | ![search](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-groups/current/after-search.png) |

| Filter popover | Filter "Inactive" |
|---|---|
| ![popover](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-groups/current/after-filter-popover.png) | ![inactive](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-groups/current/after-filter-inactive.png) |

| Group menu | Rule form with group |
|---|---|
| ![menu](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-groups/current/after-group-menu.png) | ![form](https://raw.githubusercontent.com/gfr-free/sure/pr-screenshots/rule-groups/current/after-form.png) |

### Validation

- Model tests for `Rule::Layout` (placement, reorder, stale lists), `Rule::ListFilter` (search text, split summary, hidden accounts), `RuleGroup`, rule and data import/export with groups, classifier rules with groups.
- Controller tests for groups (create, rename, taken names, delete, reorder, activation, other family's groups, guests) and rules (reorder of groups and rules, groups from the form, concurrent group creation).
- System tests: keyboard and mouse moves of groups and of rules inside a group, search and filter with sorting off, fold persistence for groups and rules, and folds kept after a refresh.
- Full `bin/rails test` on current main: 13,205 runs, 0 failures, 0 errors. Rules, accounts order and dashboard system tests pass.
- RuboCop, erb_lint, Biome and Brakeman are clean.
