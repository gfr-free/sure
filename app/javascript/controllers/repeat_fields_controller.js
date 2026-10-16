import { Controller } from "@hotwired/stimulus";

// Shows the new-transaction form's repeat settings only while "Repeat" is
// on. Hidden fields are disabled so they neither submit nor block the form
// with constraint validation.
export default class extends Controller {
  static targets = ["toggle", "fields"];

  connect() {
    this.update();
  }

  update() {
    const on = this.toggleTarget.checked;

    this.fieldsTarget.classList.toggle("hidden", !on);
    for (const field of this.fieldsTarget.querySelectorAll(
      "input, select, textarea",
    )) {
      field.disabled = !on;
    }

    // Re-enabling everything above also woke the frequency picker's hidden
    // groups; let it disable them again.
    if (on) {
      this.fieldsTarget
        .querySelector("[data-frequency-fields-target='preset']")
        ?.dispatchEvent(new Event("change"));
    }
  }
}
