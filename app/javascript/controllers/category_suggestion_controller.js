import { Controller } from "@hotwired/stimulus"

// Applies the category most commonly used on a past transaction when the user picks
// that transaction's name from the description autocomplete, and clears it again if a
// later-picked name has no usual category of its own. A manual category pick always
// wins over the suggestion, even if the name field changes afterward.
//
// The category field can be a DS::CategorySelect (transaction form) or a searchable
// DS::Select of categories (split rows); both are driven by clicking their option.
export default class extends Controller {
  static targets = ["categoryField", "name"]

  connect() {
    // A category already present when the controller connects (e.g. prefilled from
    // duplicating an existing transaction) is a deliberate default — treat it the same
    // as a manual pick so suggestions never clobber it.
    this.userPickedCategory = this.#hasCategorySelection()
    this.applyingSuggestion = false
    // The combobox reports a "selection" every time its list closes. A prefilled name (split
    // rows, duplicated transactions) only counts once the user picks a different one.
    this.lastPickedName = this.hasNameTarget ? this.nameTarget.value : ""
  }

  syncName(event) {
    // Async combobox options can arrive after submission. The visible free-text
    // value, including an intentional blank, is authoritative for the name.
    event.formData.set("entry[name]", this.nameTarget.value)
  }

  onCategorySelected(event) {
    if (this.applyingSuggestion) return
    if (event.target !== this.#categoryHiddenInput()) return

    this.userPickedCategory = true
  }

  onNameSuggestionSelected(event) {
    // Leaving the field after typing part of a name also fires a selection for the
    // highlighted option; only a name actually picked from the list carries a category.
    const { value, display } = event.detail
    if (!value || value !== display) return
    if (value === this.lastPickedName) return
    this.lastPickedName = value
    // A pick sets the value without a native "change"; announce it so a form that
    // saves on change (the transaction drawer) saves the picked name.
    if (this.hasNameTarget) this.nameTarget.dispatchEvent(new Event("change", { bubbles: true }))

    const option = event.target.querySelector(`[role="option"][data-value="${CSS.escape(value)}"]`)
    const categoryId = option?.querySelector("[data-category-id]")?.dataset.categoryId

    // A name with no usual category (categoryId undefined) still needs to clear a category
    // that was auto-applied for a previously selected name — otherwise it stays attached to
    // the new, unrelated name. #selectCategoryOption already leaves a manual pick untouched.
    this.#selectCategoryOption(categoryId || "")
  }

  #hasCategorySelection() {
    return !!this.#categoryHiddenInput()?.value
  }

  #categoryHiddenInput() {
    return this.hasCategoryFieldTarget
      ? this.categoryFieldTarget.querySelector('[data-category-select-target="hiddenInput"], [data-form-dropdown-target="input"]')
      : null
  }

  #selectCategoryOption(categoryId) {
    if (this.userPickedCategory || !this.hasCategoryFieldTarget) return

    const id = CSS.escape(String(categoryId))
    const option = this.categoryFieldTarget.querySelector(
      `[data-category-select-target="option"][data-category-id="${id}"], [data-select-target="option"][data-value="${id}"]`
    )
    if (!option) return

    // DS::Select moves focus to its trigger on a pick; keep it where the user is typing.
    const focused = document.activeElement
    this.applyingSuggestion = true
    option.click()
    this.applyingSuggestion = false
    if (focused instanceof HTMLElement && document.activeElement !== focused) focused.focus()
  }
}
