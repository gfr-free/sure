import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="confirm-dialog"
// See javascript/controllers/application.js for how this is wired up
export default class extends Controller {
  static targets = ["title", "subtitle", "confirmButton"];

  // The server renders the dialog with localized defaults; keep them for
  // confirmations that leave out a title, body or button text.
  connect() {
    this.defaults = {
      title: this.titleTarget.textContent.trim(),
      body: this.subtitleTarget.textContent.trim(),
      confirmText: this.confirmButtonTargets[0]?.textContent.trim(),
    };
  }

  // Runs on turbo:before-cache: Turbo snapshots the page as it is, and a
  // restored snapshot would otherwise hand the last confirmation's texts to
  // connect() as the "defaults" for the next one.
  reset() {
    this.titleTarget.textContent = this.defaults.title;
    this.subtitleTarget.textContent = this.defaults.body;
    this.subtitleTarget.classList.remove("privacy-sensitive");
    this.confirmButtonTargets.forEach((button) => {
      button.textContent = this.defaults.confirmText;
    });
  }

  handleConfirm(rawData) {
    const data = this.#normalizeRawData(rawData);

    this.#prepareDialog(data);

    this.element.returnValue = "";
    this.element.showModal();

    return new Promise((resolve) => {
      this.element.addEventListener(
        "close",
        () => {
          const isConfirmed = this.element.returnValue === "confirm";
          resolve(isConfirmed);
        },
        { once: true },
      );
    });
  }

  #prepareDialog(data) {
    const variant = data.variant || "primary";

    this.confirmButtonTargets.forEach((button) => {
      if (button.dataset.variant === variant) {
        button.removeAttribute("hidden");
      } else {
        button.setAttribute("hidden", true);
      }

      button.textContent = data.confirmText || this.defaults.confirmText;
    });

    this.titleTarget.textContent = data.title || this.defaults.title;
    // Text, never HTML: bodies interpolate record names (merchants, accounts,
    // brokerages, tickers) that come from bank feeds, providers and other
    // family members, however the caller built the confirmation.
    this.subtitleTarget.textContent = data.body || this.defaults.body;
    // A body that names an amount opts in to the privacy-mode blur.
    this.subtitleTarget.classList.toggle(
      "privacy-sensitive",
      data.privacySensitive === true,
    );
  }

  // If data is a string, it's the title.  Otherwise, return the parsed object.
  #normalizeRawData(rawData) {
    try {
      const parsed = JSON.parse(rawData);

      if (typeof parsed === "boolean") {
        return {};
      }

      return parsed;
    } catch (e) {
      return { title: rawData };
    }
  }
}
