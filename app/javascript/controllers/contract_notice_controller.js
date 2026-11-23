import { Controller } from "@hotwired/stimulus";

// Hides and disables the notice fields while "no notice needed" is ticked: such
// a contract keeps no notice terms, so they are not submitted.
export default class extends Controller {
  static targets = ["toggle", "field"];

  connect() {
    this.switch();
  }

  switch() {
    const hidden = this.toggleTarget.checked;

    this.fieldTargets.forEach((field) => {
      field.classList.toggle("hidden", hidden);
      field.querySelectorAll("input, select, textarea").forEach((input) => {
        input.disabled = hidden;
      });
    });
  }
}
