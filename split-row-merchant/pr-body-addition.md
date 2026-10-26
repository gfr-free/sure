### Keeping "no merchant" on split rows

Picking "(none)" for a split row's merchant in its drawer was lost on the next "Edit split": the split editor showed the row as blank, and blank there means "(transaction's merchant)", so the row got the parent's merchant again, unlocked.

- The split editor's merchant picker now has a "(no merchant)" option next to "(transaction's merchant)". Only the blank option follows the parent. A picked merchant or "(no merchant)" belongs to the row and is locked, even when it equals the parent's merchant.
- When a split is edited, each row starts on "(transaction's merchant)" only while it actually follows the parent (unlocked, same merchant). Every other row starts on its own merchant or on "(no merchant)", so saving rows unchanged keeps their merchant and lock.
- `Entry#split!` takes `own_merchant: true`; splits from rules, the API and imports are unchanged.
- `DS::MerchantSelect` accepts an optional `none_option`, rendered with the same markup as the blank option.
- The split editor lists rows in the order they were entered.

Known limitation: the API split update cannot express "no merchant of its own" or "pinned to the parent's merchant". A GET-then-PATCH round trip through the API turns those rows back into ones that follow the parent. Changing that would change the API contract, so it is left out of this PR.
