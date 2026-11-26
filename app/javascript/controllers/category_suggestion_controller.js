import { Controller } from "@hotwired/stimulus"

// Applies the category most commonly used on a past transaction when the user picks
// that transaction's name from the description autocomplete, and clears it again if a
// later-picked name has no usual category of its own. A manual category pick always
// wins over the suggestion, even if the name field changes afterward.
//
// The category field can be a DS::CategorySelect (transaction form) or a searchable
// DS::Select of categories (split rows); both are driven by clicking their option.
//
// With autoSaves (the transaction drawer, where every field saves on its own) a
// suggestion only fills an empty category, once, after the picked name is saved,
// and asks the server to keep a category that was set meanwhile (fillOnly target).
export default class extends Controller {
  static targets = ["categoryField", "name", "fillOnly"]
  static values = { autoSaves: Boolean }

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

    const option = event.target.querySelector(`[role="option"][data-value="${CSS.escape(value)}"]`)
    const categoryId = option?.querySelector("[data-category-id]")?.dataset.categoryId

    if (this.autoSavesValue) {
      this.#saveNameThenFill(value, categoryId)
      return
    }

    // A name with no usual category (categoryId undefined) still needs to clear a category
    // that was auto-applied for a previously selected name — otherwise it stays attached to
    // the new, unrelated name. #selectCategoryOption already leaves a manual pick untouched.
    this.#selectCategoryOption(categoryId || "")
  }

  // Drawer: the picked name's form saved; fill the category it suggested.
  nameSaved(event) {
    const categoryId = this.pendingCategoryId
    this.pendingCategoryId = null
    if (!categoryId || !event.detail?.success) return
    if (this.userPickedCategory || this.#hasCategorySelection()) return

    if (this.hasFillOnlyTarget) this.fillOnlyTarget.value = "1"
    this.#selectCategoryOption(categoryId)
    this.userPickedCategory = true
  }

  categorySaved() {
    if (this.hasFillOnlyTarget) this.fillOnlyTarget.value = ""
  }

  // Drawer: after a pick the browser still fires its own "change" when the field
  // is left; the pick already saved that value, so it is not sent twice.
  skipRepeatedNameChange(event) {
    if (!this.hasNameTarget || event.target !== this.nameTarget) return
    if (event.isTrusted && this.nameTarget.value === this.savedPickName) event.stopPropagation()
  }

  #saveNameThenFill(value, categoryId) {
    this.pendingCategoryId = categoryId || null
    this.savedPickName = value
    // A pick sets the value without a native "change"; the drawer saves on change.
    this.nameTarget.dispatchEvent(new Event("change", { bubbles: true }))
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
