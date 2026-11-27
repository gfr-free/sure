import { Controller } from "@hotwired/stimulus";

// Values the user typed that every trade form variant shares; a reload for a
// new type or bullion choice keeps them.
const PRESERVED_FIELDS = ["date", "qty", "price", "fee", "amount"];
// Each money field has its own currency picker under this name.
const CURRENCY_FIELD = "model[currency]";

// Connects to data-controller="trade-form"
export default class extends Controller {
  // Reloads the page with a new type without closing the modal
  async changeType(event) {
    const url = new URL(event.params.url, window.location.origin);
    url.searchParams.set(event.params.key, event.target.value);

    const values = preservedValues(this.element);
    const currencies = currencyValues(this.element);
    const frame = document.getElementById("modal");
    if (frame && (values.length > 0 || currencies.length > 0)) {
      frame.addEventListener(
        "turbo:frame-load",
        () => {
          restoreValues(frame, values);
          restoreCurrencies(frame, currencies);
        },
        { once: true },
      );
    }

    Turbo.visit(url, { frame: "modal" });
  }
}

function preservedValues(form) {
  return PRESERVED_FIELDS.map((field) =>
    form.querySelector(`[name="model[${field}]"]`),
  )
    .filter((input) => input && input.value !== "")
    .map((input) => [input.name, input.value]);
}

function restoreValues(frame, values) {
  for (const [name, value] of values) {
    const input = frame.querySelector(`[name="${name}"]`);
    if (input) input.value = value;
  }
}

function currencyValues(form) {
  return [...form.querySelectorAll(`select[name="${CURRENCY_FIELD}"]`)].map(
    (select) => select.value,
  );
}

// By position, so the price and fee keep their own currency. The change
// event lets each money field update its symbol and precision.
function restoreCurrencies(frame, currencies) {
  const selects = frame.querySelectorAll(`select[name="${CURRENCY_FIELD}"]`);
  selects.forEach((select, index) => {
    const currency = currencies[index];
    if (!currency || select.value === currency) return;
    if (![...select.options].some((option) => option.value === currency)) {
      return;
    }

    select.value = currency;
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
}
