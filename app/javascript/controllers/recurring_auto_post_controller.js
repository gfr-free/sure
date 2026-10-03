import { Controller } from "@hotwired/stimulus";

// Enables the bill form's "Post automatically" switch only while the chosen
// account, and the destination of a transfer, are manual ones. The server validates the same rule on save; this
// only keeps the form from offering a choice it would reject.
export default class extends Controller {
  static targets = ["account", "destination", "toggle", "unavailable"];
  static values = { manualIds: Array };

  connect() {
    this.update();
  }

  update() {
    if (!this.hasToggleTarget) return;

    const destination = this.hasDestinationTarget
      ? this.destinationTarget.value
      : "";
    const available =
      this.manualIdsValue.includes(this.accountTarget.value) &&
      (destination === "" || this.manualIdsValue.includes(destination));

    this.toggleTarget.disabled = !available;
    if (!available) this.toggleTarget.checked = false;
    if (this.hasUnavailableTarget) {
      this.unavailableTarget.classList.toggle("hidden", available);
    }
  }
}
