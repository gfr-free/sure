import { Controller } from "@hotwired/stimulus";

// Values the user typed that every trade form variant shares; a reload for a
// new type or bullion choice keeps them.
const PRESERVED_FIELDS = ["date", "qty", "price", "fee", "amount"];

// Connects to data-controller="trade-form"
export default class extends Controller {
  static targets = ["holdings"];

  // Reloads the page with a new type without closing the modal
  async changeType(event) {
    const url = new URL(event.params.url, window.location.origin);
    url.searchParams.set(event.params.key, event.target.value);

    const values = preservedValues(this.element);
    const frame = document.getElementById("modal");
    if (frame && values.length > 0) {
      frame.addEventListener(
        "turbo:frame-load",
        () => restoreValues(frame, values),
        { once: true },
      );
    }

    Turbo.visit(url, { frame: "modal" });
  }

  // Reloads only the sale picker for the chosen date, so the other fields
  // keep what was typed
  reloadHoldings(event) {
    if (!event.target.value || !this.hasHoldingsTarget) return;

    const url = new URL(event.params.url, window.location.origin);
    url.searchParams.set("date", event.target.value);
    this.holdingsTarget.src = url.toString();
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
