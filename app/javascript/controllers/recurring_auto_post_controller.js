import { Controller } from "@hotwired/stimulus";

// Enables the bill form's "Post automatically" switch only while the chosen
// account is a manual one. The server validates the same rule on save; this
// only keeps the form from offering a choice it would reject.
export default class extends Controller {
  static targets = ["account", "toggle", "unavailable"];
  static values = { manualIds: Array };

  connect() {
    this.update();
  }

  update() {
    if (!this.hasToggleTarget) return;

    const available = this.manualIdsValue.includes(this.accountTarget.value);

    this.toggleTarget.disabled = !available;
    if (!available) this.toggleTarget.checked = false;
    if (this.hasUnavailableTarget) {
      this.unavailableTarget.classList.toggle("hidden", available);
    }
  }
}
