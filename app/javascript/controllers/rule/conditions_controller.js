import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="rule--conditions"
export default class extends Controller {
  static values = {
    conditionFilters: Array,
    valuelessOperators: Array,
    andLabel: String,
    orLabel: String,
  };
  static targets = [
    "destroyField",
    "filterValue",
    "groupOperatorSelect",
    "operatorSelect",
    "subConditionTemplate",
    "subConditionsList",
  ];

  connect() {
    // A condition group has no operator/value fields of its own, only sub-conditions
    if (this.hasSubConditionsListTarget) {
      this.updateSubConditionPrefixes();
      return;
    }

    // Hide value field on initial load for valueless operators (e.g. "is_null")
    this.#toggleValueFieldVisibility();
  }

  addSubCondition() {
    const html = this.subConditionTemplateTarget.innerHTML.replaceAll(
      "IDX_CHILD_PLACEHOLDER",
      this.#uniqueKey(),
    );

    this.subConditionsListTarget.insertAdjacentHTML("beforeend", html);
    this.updateSubConditionPrefixes();
  }

  // Shows "or"/"and" between the sub-conditions of a group, matching the group's operator
  updateSubConditionPrefixes() {
    if (!this.hasSubConditionsListTarget) return;

    const label =
      this.groupOperatorSelectTarget.value === "or"
        ? this.orLabelValue
        : this.andLabelValue;
    const subConditions = Array.from(
      this.subConditionsListTarget.children,
    ).filter((el) => !el.classList.contains("hidden"));

    subConditions.forEach((subCondition, index) => {
      const prefixEl = subCondition.querySelector("[data-condition-prefix]");
      if (!prefixEl) return;

      prefixEl.classList.toggle("hidden", index === 0);
      const labelEl = prefixEl.querySelector("[data-condition-prefix-label]");
      if (labelEl) labelEl.textContent = label;
    });
  }

  remove(e) {
    e.preventDefault();
    e.stopPropagation();
    
    // Find the parent rules controller and condition group (if any) before removing the condition
    const rulesEl = this.element.closest('[data-controller~="rules"]');
    const groupEl = this.element.parentElement?.closest(
      '[data-controller~="rule--conditions"]',
    );

    if (e.params.destroy) {
      this.destroyFieldTarget.value = true;
      this.element.classList.add("hidden");
    } else {
      this.element.remove();
    }

    // Update the prefixes of all conditions from the parent rules controller
    if (rulesEl) {
      const rulesController = this.application.getControllerForElementAndIdentifier(rulesEl, "rules");
      if (rulesController && typeof rulesController.updateConditionPrefixes === "function") {
        rulesController.updateConditionPrefixes();
      }
    }

    if (groupEl) {
      const groupController =
        this.application.getControllerForElementAndIdentifier(
          groupEl,
          "rule--conditions",
        );
      groupController?.updateSubConditionPrefixes();
    }
  }

  handleConditionTypeChange(e) {
    const conditionFilter = this.conditionFiltersValue.find(
      (filter) => filter.key === e.target.value,
    );

    if (conditionFilter.type === "select") {
      this.#buildSelectFor(conditionFilter);
    } else {
      this.#buildTextInputFor(conditionFilter);
    }

    this.#updateOperatorsField(conditionFilter);
    this.#toggleValueFieldVisibility();
  }

  handleOperatorChange(e) {
    this.#toggleValueFieldVisibility();
  }

  get valueInputEl() {
    const textInput = this.filterValueTarget.querySelector("input");
    const selectInput = this.filterValueTarget.querySelector("select");

    return textInput || selectInput;
  }

  #updateOperatorsField(conditionFilter) {
    this.operatorSelectTarget.innerHTML = "";

    for (const operator of conditionFilter.operators) {
      const optionEl = document.createElement("option");
      optionEl.value = operator[1];
      optionEl.textContent = operator[0];
      this.operatorSelectTarget.appendChild(optionEl);
    }
  }

  #buildSelectFor(conditionFilter) {
    const selectEl = this.#convertFormFieldTo("select", this.valueInputEl);

    for (const option of conditionFilter.options) {
      const optionEl = document.createElement("option");
      optionEl.value = option[1];
      optionEl.textContent = option[0];
      selectEl.appendChild(optionEl);
    }

    this.valueInputEl.replaceWith(selectEl);
  }

  #buildTextInputFor(conditionFilter) {
    const textInput = this.#convertFormFieldTo("input", this.valueInputEl);
    textInput.placeholder = "Enter a value";
    textInput.type = conditionFilter.type; // "text" || "number"
    if (conditionFilter.type === "number") {
      textInput.step = conditionFilter.number_step;
    }

    this.valueInputEl.replaceWith(textInput);
  }

  #convertFormFieldTo(type, el) {
    const priorClasses = el.classList;
    const priorId = el.id;
    const priorName = el.name;

    const newFormField = document.createElement(type);
    newFormField.classList.add(...priorClasses);
    newFormField.id = priorId;
    newFormField.name = priorName;

    return newFormField;
  }

  #uniqueKey() {
    this.keySequence = (this.keySequence ?? 0) + 1;
    return Date.now() * 1000 + this.keySequence;
  }

  #toggleValueFieldVisibility() {
    const operator = this.operatorSelectTarget.value;

    if (this.valuelessOperatorsValue.includes(operator)) {
      this.filterValueTarget.classList.add("hidden");
      // Clear the value since it's not needed
      if (this.valueInputEl) {
        this.valueInputEl.value = "";
      }
    } else {
      this.filterValueTarget.classList.remove("hidden");
    }
  }
}
