import { Controller } from "@hotwired/stimulus"

// Split rows are real, individually-named form fields rendered server-side (via the
// "splits/row" partial) and cloned from a <template> for new rows — mirrors
// rule--split-action, which took the same approach after a hand-rolled JS-serialized
// blob proved fragile in practice. Cloning from the template means new rows automatically
// pick up whatever fields the partial renders (category/merchant/tag selects included)
// without this controller needing to know about them.
export default class extends Controller {
  static targets = ["rowsContainer", "row", "rowTemplate", "amountInput", "remaining", "remainingContainer", "error", "submitButton", "nameInput"]
  static values = { total: Number, currency: String }

  connect() {
    this.updateRemaining()
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

  // Runs from the form's input action, after the row's own updateRemaining.
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
    const sum = this.amountInputTargets.reduce((acc, input) => {
      return acc + (Number.parseFloat(input.value) || 0)
    }, 0)

    const remaining = total - sum
    const absRemaining = Math.abs(remaining)
    const balanced = absRemaining < 0.005

    this.remainingTarget.textContent = balanced ? "0.00" : remaining.toFixed(2)

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
}
