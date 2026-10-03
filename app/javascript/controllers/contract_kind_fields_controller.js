import { Controller } from "@hotwired/stimulus";

// Shows the kind-specific fields of the selected contract kind and disables
// the others, so only the current kind's details are submitted.
export default class extends Controller {
  static targets = ["kind", "group"];

  connect() {
    this.switch();
  }

  switch() {
    const kind = this.kindTarget.value;

    this.groupTargets.forEach((group) => {
      const active = group.dataset.kind === kind;
      group.classList.toggle("hidden", !active);
      group.querySelectorAll("input, select, textarea").forEach((field) => {
        field.disabled = !active;
      });
    });
  }
}
