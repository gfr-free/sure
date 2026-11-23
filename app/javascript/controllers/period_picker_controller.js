import { Controller } from "@hotwired/stimulus";

// Opens the period picker's custom range dialog and keeps its two date fields
// at least one day apart, the shortest range the chart can draw.
export default class extends Controller {
  static targets = ["trigger", "dialog", "form", "startDate", "endDate"];
  static values = { customSelected: Boolean };

  open() {
    // The menu sits below the modal; leaving it open would show it again,
    // stale, once the dialog closes.
    this.#menuController()?.close();
    // Back to the range the chart shows: edits abandoned with Cancel or
    // Escape must not come back on the next open.
    this.formTarget.reset();
    this.syncBounds();
    this.dialogTarget.showModal();
    this.startDateTarget.focus();
  }

  syncBounds() {
    if (this.startDateTarget.value) {
      this.endDateTarget.min = shiftDate(this.startDateTarget.value, 1);
    }
    this.startDateTarget.max = shiftDate(
      this.endDateTarget.value || this.endDateTarget.max,
      -1,
    );
  }

  // Re-applying the custom range already shown changes nothing, so it replaces
  // the history entry instead of stacking a duplicate, like the checked row.
  submit() {
    const unchanged =
      this.customSelectedValue &&
      this.startDateTarget.value === this.startDateTarget.defaultValue &&
      this.endDateTarget.value === this.endDateTarget.defaultValue;
    this.formTarget.dataset.turboAction = unchanged ? "replace" : "advance";
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

// Shifts an ISO date (YYYY-MM-DD) by whole days, in UTC so no time zone or DST
// change can move it by a day.
function shiftDate(isoDate, days) {
  const date = new Date(`${isoDate}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}
