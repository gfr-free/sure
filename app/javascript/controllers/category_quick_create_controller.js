import { Controller } from "@hotwired/stimulus";
import { createCategory } from "utils/category_create";
import { enterMatch, exactName, isComposing } from "utils/search_match";

// Lets the transaction list's quick category picker create a category that
// doesn't exist yet, optionally under a top-level parent. The new category is
// assigned by submitting the same update form a normal row uses, so the row
// refreshes in place and the "create a rule?" prompt still appears.
//
// The create targets are only rendered when the user may annotate the
// account; without them this controller does nothing.
export default class extends Controller {
  static targets = [
    "input",
    "createButton",
    "createLabel",
    "assignForm",
    "categoryIdField",
    "error",
    "list",
    "createAsSubcategory",
    "parentPicker",
    "parentPickerLabel",
  ];

  static values = {
    createUrl: String,
    color: String,
    labelTemplate: String,
    errorMessage: String,
    assignErrorMessage: String,
    existingNames: Array,
    parentPickerLabel: String,
  };

  connect() {
    this.onAssignEnd = (event) => this.#assignFinished(event);
    this.onFrameMissing = (event) => this.#assignResponseMissing(event);
    this.frame = this.element.closest("turbo-frame");

    if (this.hasAssignFormTarget) {
      this.assignFormTarget.addEventListener(
        "turbo:submit-end",
        this.onAssignEnd,
      );
    }
    this.frame?.addEventListener("turbo:frame-missing", this.onFrameMissing);
    this.update();
  }

  disconnect() {
    if (this.hasAssignFormTarget) {
      this.assignFormTarget.removeEventListener(
        "turbo:submit-end",
        this.onAssignEnd,
      );
    }
    this.frame?.removeEventListener("turbo:frame-missing", this.onFrameMissing);
  }

  update() {
    if (!this.hasCreateButtonTarget) return;

    // Editing the name returns to the list, so the picker never shows a stale name.
    this.hideParentPicker();

    const name = this.inputTarget.value.trim();
    const canCreate = name.length > 0 && !this.#nameExists(name);

    this.#toggle(this.createButtonTarget, canCreate);
    if (this.hasCreateAsSubcategoryTarget) {
      this.#toggle(this.createAsSubcategoryTarget, canCreate);
    }

    if (canCreate) {
      this.createLabelTarget.textContent = this.labelTemplateValue.replace(
        "__NAME__",
        name,
      );
      // list-filter shows "No categories found" when nothing matches; with a
      // create option on offer that reads as a contradiction, so hide it.
      this.element
        .querySelector("[data-list-filter-target='emptyMessage']")
        ?.classList.add("hidden");
    }

    this.#clearError();
  }

  // The same Enter rule as the category select (utils/search_match
  // enterMatch): an existing row the search names wins, else Enter creates
  // while the create row shows, else it picks the first visible row. A row
  // picked with the arrow keys wins over all of it (list-filter submits it).
  createOnEnter(event) {
    if (isComposing(event)) return;
    if (this.#parentPickerOpen || this.#hasHighlightedRow) return;

    const query = this.inputTarget.value.trim();
    if (!query) return;

    const rows = this.#visibleRows;
    const existing = enterMatch(rows, query);

    if (
      !existing &&
      this.hasCreateButtonTarget &&
      !this.createButtonTarget.classList.contains("hidden")
    ) {
      event.preventDefault();
      this.create();
      return;
    }

    const form = (existing ?? rows[0])?.querySelector("form");
    if (!form) return;

    event.preventDefault();
    form.requestSubmit();
  }

  showParentPicker(event) {
    event?.preventDefault();
    if (!this.hasParentPickerTarget) return;

    const name = this.inputTarget.value.trim();
    if (!name) return;

    this.parentPickerLabelTarget.textContent =
      this.parentPickerLabelValue.replace("__NAME__", name);

    this.listTarget.classList.add("hidden");
    this.#toggle(this.parentPickerTarget, true);
  }

  hideParentPicker(event) {
    event?.preventDefault();
    if (!this.hasParentPickerTarget) return;

    this.#toggle(this.parentPickerTarget, false);
    this.listTarget.classList.remove("hidden");
  }

  createUnderParent(event) {
    event.preventDefault();
    this.create(event.currentTarget.dataset.parentId);
  }

  // Called directly as an action (receives an Event) or with a parent id.
  async create(parentIdOrEvent = null) {
    if (this.creating || !this.hasCreateButtonTarget) return;
    const parentId =
      typeof parentIdOrEvent === "string" ? parentIdOrEvent : null;

    const name = this.inputTarget.value.trim();
    if (!name) return;

    this.creating = true;
    this.createButtonTarget.disabled = true;
    this.#clearError();

    try {
      // A retry after a failed assignment reuses the category created the
      // first time; posting it again would fail as a duplicate name.
      let category = this.#createdCategory(name, parentId);
      if (!category) {
        const result = await createCategory({
          url: this.createUrlValue,
          name,
          color: this.colorValue,
          parentId,
        });
        category = result.category;

        if (!category) {
          this.hideParentPicker();
          this.#showError(result.error || this.errorMessageValue);
          return;
        }
        this.created = { name, parentId, id: category.id };
      }

      this.categoryIdFieldTarget.value = category.id;
      this.assigning = true;
      this.assignFormTarget.requestSubmit();
    } finally {
      this.creating = false;
      this.createButtonTarget.disabled = false;
    }
  }

  // The category exists once create succeeds; if the assignment then fails
  // (network, session, permission) say so rather than failing silently.
  #assignFinished(event) {
    const failed = this.assigning && !event.detail?.success;
    this.assigning = false;
    if (!failed) return;

    this.hideParentPicker();
    this.#showError(this.assignErrorMessageValue);
  }

  // An error or redirect response has no matching frame, so Turbo would swap
  // the picker for its generic "Content missing" message. Keep the picker and
  // explain what happened instead.
  #assignResponseMissing(event) {
    if (!this.assigning) return;

    event.preventDefault();
    this.assigning = false;
    this.hideParentPicker();
    this.#showError(this.assignErrorMessageValue);
  }

  // Only the same choice (name and parent) is a retry; choosing a different
  // parent for that name is a new create, which the server then validates.
  #createdCategory(name, parentId) {
    if (
      exactName(this.created?.name) !== exactName(name) ||
      this.created.parentId !== parentId
    ) {
      return null;
    }
    return { id: this.created.id };
  }

  // Same "exists" rule as the category select (utils/search_match).
  #nameExists(name) {
    const wanted = exactName(name);
    return this.existingNamesValue.some(
      (existing) => exactName(existing) === wanted,
    );
  }

  get #parentPickerOpen() {
    return (
      this.hasParentPickerTarget &&
      !this.parentPickerTarget.classList.contains("hidden")
    );
  }

  get #visibleRows() {
    return Array.from(this.element.querySelectorAll(".filterable-item")).filter(
      (item) => item.style.display !== "none" && item.offsetParent !== null,
    );
  }

  get #hasHighlightedRow() {
    return this.inputTarget.hasAttribute("aria-activedescendant");
  }

  #toggle(element, visible) {
    element.classList.toggle("hidden", !visible);
    element.classList.toggle("flex", visible);
  }

  #showError(message) {
    this.errorTarget.textContent = message;
    this.errorTarget.classList.remove("hidden");
  }

  #clearError() {
    if (!this.hasErrorTarget) return;

    this.errorTarget.textContent = "";
    this.errorTarget.classList.add("hidden");
  }
}
