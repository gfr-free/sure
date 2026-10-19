import { Controller } from "@hotwired/stimulus";

// Fills a contract's term fields with the typical terms for its kind, only
// when the user asks. The suggestions come from Contract::LegalDefaults and
// are rendered into a data value; kinds without suggestions leave the
// fields untouched.
export default class extends Controller {
  static targets = ["kind", "field"];
  static values = { defaults: Object };

  apply(event) {
    event.preventDefault();

    const suggestion = this.defaultsValue[this.kindTarget.value];
    if (!suggestion) return;

    this.fieldTargets.forEach((field) => {
      const key = field.dataset.contractDefaultsKey;
      if (!(key in suggestion)) return;

      const value = suggestion[key];
      field.value = value === null || value === undefined ? "" : String(value);
      field.dispatchEvent(new Event("change", { bubbles: true }));
    });
  }
}
