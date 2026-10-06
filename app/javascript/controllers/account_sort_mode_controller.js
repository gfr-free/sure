import { Controller } from "@hotwired/stimulus";

// Sort mode of the account sidebar, used with the manual account order.
// The drag handles stay hidden until the user turns sort mode on, so the
// list looks the same as with the other orders the rest of the time.
// Visibility is set inline (not with Tailwind classes) because the Docker
// image ships a precompiled CSS bundle, like the expand-all toggle.
export default class extends Controller {
  static targets = ["toggle", "bar", "handle"];

  connect() {
    this.sorting = false;
  }

  toggle() {
    this.sorting ? this.stop() : this.start();
  }

  start() {
    this.sorting = true;
    this.render();
    // Handles inside collapsed groups would stay out of sight.
    this.handleTargets.forEach((handle) => {
      const group = handle.closest("details");
      if (group) group.open = true;
    });
  }

  stop() {
    const active = document.activeElement;
    const focusWillHide =
      this.handleTargets.includes(active) ||
      this.barTargets.some((bar) => bar.contains(active));

    // A row picked up with the keyboard is dropped and saved where it is.
    window.dispatchEvent(new CustomEvent("account-sort-mode:stop"));

    this.sorting = false;
    this.render();
    if (focusWillHide) this.visibleToggle()?.focus();
  }

  // Handles rendered later (e.g. another tab's list) follow the current mode.
  handleTargetConnected(handle) {
    handle.style.display = this.sorting ? "" : "none";
  }

  // Also runs after a Turbo morph refresh, which restores the server markup.
  render() {
    const display = this.sorting ? "" : "none";
    this.handleTargets.forEach((handle) => {
      handle.style.display = display;
    });
    this.barTargets.forEach((bar) => {
      bar.style.display = display;
    });
    this.toggleTargets.forEach((toggle) => {
      toggle.setAttribute("aria-pressed", this.sorting ? "true" : "false");
      toggle.classList.toggle("bg-surface-inset", this.sorting);
    });
  }

  visibleToggle() {
    return this.toggleTargets.find((toggle) => toggle.offsetParent !== null);
  }
}
