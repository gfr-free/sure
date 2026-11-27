import { Controller } from "@hotwired/stimulus"
import comboboxHiddenField from "utils/combobox_hidden_field"
import { precisionFromStep } from "utils/evaluate_amount_expression"
import submittedAmount from "utils/submitted_amount"

// Split rows are real, individually-named form fields rendered server-side (via the
// "splits/row" partial) and cloned from a <template> for new rows — mirrors
// rule--split-action, which took the same approach after a hand-rolled JS-serialized
// blob proved fragile in practice. Cloning from the template means new rows automatically
// pick up whatever fields the partial renders (category/merchant/tag selects included)
// without this controller needing to know about them.
export default class extends Controller {
  static targets = ["rowsContainer", "row", "rowTemplate", "amountInput", "remaining", "remainingContainer", "error", "submitButton", "nameInput"]
  static values = { total: Number, currency: String, generateNames: Boolean, defaultName: String }

  connect() {
    this.updateRemaining()
    this.updateNamePlaceholders()
  }

  get rowCount() {
    return this.rowTargets.length
  }

  addRow() {
    // Seeded from Date.now() (so it can't collide with existing server-rendered row indices,
    // e.g. 0/1/2 for an already-split transaction's children) but incremented monotonically
    // from there — two rows added within the same millisecond would otherwise get the same
    // index, producing duplicate field names that silently drop one row.
    this.nextRowIndex ??= Date.now()
    const html = this.rowTemplateTarget.innerHTML.replaceAll("ROW_IDX_PLACEHOLDER", this.nextRowIndex++)
    this.rowsContainerTarget.insertAdjacentHTML("beforeend", html)

    // The newest row takes what is still unassigned and keeps following it while other
    // amounts change, until the user edits it. An earlier row keeps what it shows.
    for (const input of this.amountInputTargets) delete input.dataset.followsRemaining
    const newRow = this.rowTargets[this.rowTargets.length - 1]
    newRow.querySelector("[data-split-transaction-target='amountInput']").dataset.followsRemaining = ""

    this.updateRemaining()
    this.fillFollowingRow()
    this.updateNamePlaceholders()
  }

  // Name suggestions load asynchronously and can update a row's hidden name field after the
  // user has moved on. The visible text, including an intentional blank, is what gets saved.
  syncNames(event) {
    this.nameInputTargets.forEach((input) => {
      const hiddenField = comboboxHiddenField(input)
      if (hiddenField?.name) event.formData.set(hiddenField.name, input.value)
    })
  }

  removeRow(event) {
    event.stopPropagation()
    const row = event.target.closest("[data-split-transaction-target='row']")
    if (row && this.rowCount > 1) {
      row.remove()
      this.updateRemaining()
      this.fillFollowingRow()
    }
  }

  // Runs from the rows container's input action, after the row's own updateRemaining.
  followRemaining(event) {
    const input = event.target
    if (!this.amountInputTargets.includes(input)) return

    if (input === this.followingInput()) {
      delete input.dataset.followsRemaining
    } else {
      this.fillFollowingRow()
    }
  }

  // The following row carries the amount this controller last wrote into it, so its own share
  // is never parsed back from typed text. A field whose text no longer matches was changed by
  // something else and stops following.
  followingInput() {
    return this.amountInputTargets.find(
      (input) => input.dataset.followsRemaining !== undefined && input.value === input.dataset.followsRemaining
    )
  }

  // Sets the following row to the open balance as the indicator shows it (which already
  // counts that row). Nothing left, or more assigned than the total, leaves the row empty,
  // so the indicator shows the overshoot instead of the row taking the opposite sign.
  fillFollowingRow() {
    const input = this.followingInput()
    if (!input) return

    const remaining = this.remainingTarget.textContent.trim()
    const decimals = (remaining.split(".")[1] || "").length
    const amount = Number((Number(input.dataset.followsRemaining) + Number(remaining)).toFixed(decimals))
    const fits = amount !== 0 && Math.sign(amount) === Math.sign(this.totalValue)

    input.value = fits ? amount.toFixed(decimals) : ""
    input.dataset.followsRemaining = input.value
    this.updateRemaining()
  }

  updateRemaining() {
    const total = this.totalValue
    // A saved row can carry more decimals than the currency, so each row is
    // read with its own precision and the balance uses the finest of them and
    // of the total, which Entry#split! must match exactly.
    let precision = Math.min((String(total).split(".")[1] || "").length, 4)
    const sum = this.amountInputTargets.reduce((acc, input) => {
      const rowPrecision = precisionFromStep(input.step) ?? 2
      precision = Math.max(precision, rowPrecision)
      // Each row as its money field submits it (rounded to its precision), so
      // "100/3" in three rows shows the 0.01 that Entry#split! will reject.
      return acc + (submittedAmount(this.application, input, rowPrecision) || 0)
    }, 0)

    const remaining = total - sum
    const balanced = Math.abs(remaining) < 0.5 * 10 ** -precision

    this.remainingTarget.textContent = (balanced ? 0 : remaining).toFixed(precision)

    // Visual feedback on remaining balance
    const container = this.remainingContainerTarget

    if (balanced) {
      this.remainingTarget.classList.remove("text-destructive")
      this.remainingTarget.classList.add("text-success")
      container.classList.remove("border-destructive", "bg-red-tint-10")
      container.classList.add("border-green-200", "bg-green-tint-10")
    } else {
      this.remainingTarget.classList.remove("text-success")
      this.remainingTarget.classList.add("text-destructive")
      container.classList.remove("border-green-200", "bg-green-tint-10")
      container.classList.add("border-destructive", "bg-red-tint-10")
    }

    this.errorTarget.classList.toggle("hidden", balanced)
    this.submitButtonTarget.disabled = !balanced
  }

  // With generated names on, a row submitted without a name is saved as "Category - Merchant"
  // (SplitsController), so each name field shows that name as its placeholder.
  updateNamePlaceholders() {
    if (!this.generateNamesValue) return

    this.rowTargets.forEach((row) => {
      const input = row.querySelector("[data-split-transaction-target='nameInput']")
      if (input) input.placeholder = this.#defaultRowName(row)
    })
  }

  #defaultRowName(row) {
    const parts = [this.#categoryName(row), this.#merchantName(row)].filter(Boolean)
    return parts.length > 0 ? parts.join(" - ") : this.defaultNameValue
  }

  #categoryName(row) {
    const id = row.querySelector("input[type='hidden'][name$='[category_id]']")?.value
    if (!id) return null

    return row.querySelector(`.category-select-container [role='option'][data-value='${CSS.escape(id)}']`)?.dataset.filterName?.trim() || null
  }

  #merchantName(row) {
    const id = row.querySelector("[data-merchant-select-target='hiddenInput']")?.value
    if (!id) return null

    return row.querySelector(`[data-merchant-select-target='option'][data-merchant-id='${CSS.escape(id)}']`)?.dataset.merchantName || null
  }
}
