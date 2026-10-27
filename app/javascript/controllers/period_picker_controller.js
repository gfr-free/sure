import { Controller } from "@hotwired/stimulus";

// Opens the period picker's custom range dialog and keeps its two date fields
// from describing a backwards range.
export default class extends Controller {
  static targets = ["trigger", "dialog", "startDate", "endDate"];

  open() {
    // The menu sits below the modal; leaving it open would show it again,
    // stale, once the dialog closes.
    this.#menuController()?.close();
    this.dialogTarget.showModal();
    this.startDateTarget.focus();
  }

  syncBounds() {
    this.endDateTarget.min = this.startDateTarget.value;
    this.startDateTarget.max =
      this.endDateTarget.value || this.endDateTarget.max;
  }

  // The menu item that opened the dialog is hidden by now, so focus goes back
  // to the trigger instead.
  restoreFocus() {
    if (this.hasTriggerTarget) this.triggerTarget.focus();
  }

  #menuController() {
    const menu = this.triggerTarget.closest("[data-controller~='DS--menu']");
    return (
      menu &&
      this.application.getControllerForElementAndIdentifier(menu, "DS--menu")
    );
  }
}
