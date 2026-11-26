import { Controller } from "@hotwired/stimulus"
import submittedAmount from "utils/submitted_amount"

// cost_basis stores the per-share cost with four decimals.
const PER_SHARE_DECIMALS = 4

// Handles bidirectional conversion between total cost basis and per-share cost
// in the manual cost basis entry form. Only the per-share field is submitted.
export default class extends Controller {
  static targets = ["total", "perShare"]
  static values = { qty: Number }

  // Called when user types in the total cost basis field
  // Updates the per-share field with the calculated value, keeping up to four
  // decimals so a price below a cent is not saved as 0.00
  updatePerShare() {
    // An empty total empties the submitted per-share field instead of saving 0
    if (this.totalTarget.value.trim() === "") {
      this.perShareTarget.value = ""
      return
    }

    // Both fields are money fields, read the way they submit ("12,345" in a
    // euro field is 12.345, not a grouped 12345).
    const total = submittedAmount(this.application, this.totalTarget)
    if (total === null) return
    const qty = this.qtyValue || 1
    this.perShareTarget.value = qty > 0 ? this.#formatPerShare(total / qty) : "0.00"
  }

  // Called when user types in the per-share field
  // Updates the total cost basis field with the calculated value
  updateTotal() {
    if (this.perShareTarget.value.trim() === "") {
      this.totalTarget.value = ""
      return
    }

    const perShare = submittedAmount(this.application, this.perShareTarget)
    if (perShare === null) return
    const qty = this.qtyValue || 1
    this.totalTarget.value = (perShare * qty).toFixed(2)
  }

  // At least two decimals, more only when the value needs them.
  #formatPerShare(value) {
    return value.toFixed(PER_SHARE_DECIMALS).replace(/0{1,2}$/, "")
  }
}
