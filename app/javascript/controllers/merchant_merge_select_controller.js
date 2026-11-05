import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="merchant-merge-select"
// "Select all" for the merge merchants dialog. It only touches rows the
// list-filter search leaves visible and never selects the chosen target,
// and keeps the submit confirmation in sync with the number of merchants
// that will actually be merged.
export default class extends Controller {
  static targets = ["selectAll", "source", "targetInput", "count", "submit"];
  static values = {
    countOne: String,
    countOther: String,
    confirmTitle: String,
    confirmBodyOne: String,
    confirmBodyOther: String,
    confirmText: String,
  };

  connect() {
    this.refresh();
  }

  toggleAll(event) {
    const checked = event.target.checked;
    this.visibleSources.forEach((source) => {
      source.checked = checked && !this.isTarget(source);
    });
    this.refresh();
  }

  // The merger skips the target anyway, so a target that was ticked as a
  // source is unticked to keep the count honest.
  targetChanged() {
    this.sourceTargets.forEach((source) => {
      if (this.isTarget(source)) source.checked = false;
    });
    this.refresh();
  }

  refresh() {
    const eligible = this.visibleSources.filter(
      (source) => !this.isTarget(source),
    );
    const checkedEligible = eligible.filter((source) => source.checked).length;

    if (this.hasSelectAllTarget) {
      this.selectAllTarget.disabled = eligible.length === 0;
      this.selectAllTarget.checked =
        eligible.length > 0 && checkedEligible === eligible.length;
      this.selectAllTarget.indeterminate =
        checkedEligible > 0 && checkedEligible < eligible.length;
    }

    const count = this.selectedSources.length;

    if (this.hasCountTarget) {
      this.countTarget.textContent = this.pluralize(
        count,
        this.countOneValue,
        this.countOtherValue,
      );
    }

    this.updateConfirmation(count);
  }

  updateConfirmation(count) {
    if (!this.hasSubmitTarget) return;

    const targetName = this.targetName;
    if (count === 0 || !targetName) {
      delete this.submitTarget.dataset.turboConfirm;
      return;
    }

    const body = this.pluralize(
      count,
      this.confirmBodyOneValue,
      this.confirmBodyOtherValue,
    ).replace("%{target}", () => targetName);

    this.submitTarget.dataset.turboConfirm = JSON.stringify({
      title: this.confirmTitleValue,
      body,
      confirmText: this.confirmTextValue,
      variant: "destructive",
    });
  }

  pluralize(count, one, other) {
    return (count === 1 ? one : other).replace("%{count}", count);
  }

  isTarget(source) {
    return (
      this.hasTargetInputTarget &&
      this.targetInputTarget.value !== "" &&
      source.value === this.targetInputTarget.value
    );
  }

  // Checked rows stay selected while a search hides them, so they count.
  get selectedSources() {
    return this.sourceTargets.filter(
      (source) => source.checked && !this.isTarget(source),
    );
  }

  get visibleSources() {
    return this.sourceTargets.filter(
      (source) => source.closest(".filterable-item")?.style.display !== "none",
    );
  }

  get targetName() {
    if (!this.hasTargetInputTarget || this.targetInputTarget.value === "")
      return null;

    const row = this.sourceTargets
      .find((source) => source.value === this.targetInputTarget.value)
      ?.closest(".filterable-item");
    return row?.dataset.filterName || null;
  }
}
