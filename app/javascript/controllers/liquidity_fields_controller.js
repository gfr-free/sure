import { Controller } from "@hotwired/stimulus";

// Shows the release-date fields only while the account is locked: either
// chosen by hand, or "automatic" on a subtype whose default is locked. Follows
// the subtype select in the same form, so switching a savings account to a
// term deposit before saving shows the date it now needs. The family's own
// subtype select, when present, takes precedence over the built-in one.
export default class extends Controller {
  static targets = ["level", "lockedFields"];
  static values = {
    defaultLevel: String,
    defaults: Object,
    customDefaults: Object,
    labels: Object,
    automaticTemplate: String,
  };

  connect() {
    const form = this.element.closest("form");
    this.subtypeSelect = form?.querySelector("select[name$='[subtype]']");
    this.customSubtypeSelect = form?.querySelector(
      "select[name$='[custom_account_subtype_id]']",
    );
    this.onDefaultChange = () => this.defaultChanged();
    this.subtypeSelect?.addEventListener("change", this.onDefaultChange);
    this.customSubtypeSelect?.addEventListener("change", this.onDefaultChange);
    this.refresh();
  }

  disconnect() {
    this.subtypeSelect?.removeEventListener("change", this.onDefaultChange);
    this.customSubtypeSelect?.removeEventListener(
      "change",
      this.onDefaultChange,
    );
  }

  defaultChanged() {
    const level = this.currentDefaultLevel();
    if (!level) return;

    this.defaultLevelValue = level;
    const automatic = this.levelTarget.querySelector(
      "option[value='automatic']",
    );
    if (automatic) {
      automatic.textContent = this.automaticTemplateValue.replace(
        "__LEVEL__",
        this.labelsValue[level] || level,
      );
    }
    this.refresh();
  }

  currentDefaultLevel() {
    const customId = this.customSubtypeSelect?.value;
    if (customId) return this.customDefaultsValue[customId];

    return this.defaultsValue[
      this.subtypeSelect ? this.subtypeSelect.value : ""
    ];
  }

  refresh() {
    const level = this.levelTarget.value;
    const locked =
      level === "locked" ||
      (level === "automatic" && this.defaultLevelValue === "locked");

    this.lockedFieldsTargets.forEach((field) => {
      field.classList.toggle("hidden", !locked);
    });
  }
}
