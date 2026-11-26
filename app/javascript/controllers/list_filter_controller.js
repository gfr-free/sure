import { Controller } from "@hotwired/stimulus";
import {
  hasSearchQuery,
  isComposing,
  matchesSearch,
} from "utils/search_match";

// Filters a list by the shared search rule in utils/search_match: each
// .filterable-item is found by its data-filter-name and data-filter-terms.
export default class extends Controller {
  static targets = ["input", "list", "emptyMessage", "recentSection"];

  connect() {
    this.inputTarget.focus();
    this.highlightedIndex = -1;
    this.updateAriaActiveDescendant();

    this.hostDetails = this.element.closest("details");
    if (this.hostDetails) {
      this._onHostToggle = () => {
        if (this.hostDetails.open) {
          this.inputTarget.focus();
        } else {
          this.reset();
        }
      };
      this.hostDetails.addEventListener("toggle", this._onHostToggle);
    }
  }

  disconnect() {
    if (this.hostDetails) {
      this.hostDetails.removeEventListener("toggle", this._onHostToggle);
    }
  }

  reset() {
    this.inputTarget.value = "";
    this.filter();
  }

  filter() {
    const rawFilterValue = this.inputTarget.value;
    const items = this.listTarget.querySelectorAll(".filterable-item");
    let noMatchFound = true;

    // "Recent" is a pre-search shortcut only — once the user is actively
    // searching, show canonical filtered results, not a duplicate row. Its
    // items are hidden outright (not text-matched) so the now-ancestor-hidden
    // section can't leave a row with display:"" that arrow-key nav would
    // still treat as visible.
    const recentItems = this.hasRecentSectionTarget
      ? new Set(this.recentSectionTarget.querySelectorAll(".filterable-item"))
      : new Set();

    const searching = hasSearchQuery(rawFilterValue);
    if (this.hasRecentSectionTarget) {
      this.recentSectionTarget.classList.toggle("hidden", searching);
    }

    if (this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.add("hidden");
    }

    items.forEach((item) => {
      const shouldDisplay =
        !(searching && recentItems.has(item)) &&
        matchesSearch(item, rawFilterValue);
      item.style.display = shouldDisplay ? "" : "none";

      if (shouldDisplay) {
        noMatchFound = false;
      }
    });

    if (noMatchFound && this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.remove("hidden");
    }

    this.highlightedIndex = -1;
    this.clearHighlights();
    this.updateAriaActiveDescendant();
  }

  handleKeydown(event) {
    if (isComposing(event)) return;

    if (event.key === "ArrowDown") {
      event.preventDefault();
      this.highlightNext();
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      this.highlightPrevious();
    } else if (event.key === "Enter") {
      event.preventDefault();
      this.selectHighlighted();
    }
  }

  highlightNext() {
    const items = this.visibleItems;
    if (items.length === 0) return;

    this.clearHighlights();
    this.highlightedIndex = Math.min(
      this.highlightedIndex + 1,
      items.length - 1,
    );
    this.highlightItem(items[this.highlightedIndex]);
    this.updateAriaActiveDescendant();
  }

  highlightPrevious() {
    const items = this.visibleItems;
    if (items.length === 0) return;

    this.clearHighlights();
    this.highlightedIndex = Math.max(this.highlightedIndex - 1, 0);
    this.highlightItem(items[this.highlightedIndex]);
    this.updateAriaActiveDescendant();
  }

  highlightItem(item) {
    item.classList.add("bg-container-inset-hover");
    item.setAttribute("aria-selected", "true");
    item.scrollIntoView({ block: "nearest" });
  }

  clearHighlights() {
    this.listTarget.querySelectorAll(".filterable-item").forEach((item) => {
      item.classList.remove("bg-container-inset-hover");
      if (item.hasAttribute("aria-selected")) {
        item.setAttribute("aria-selected", "false");
      }
    });
  }

  selectHighlighted() {
    const items = this.visibleItems;
    if (this.highlightedIndex < 0 || this.highlightedIndex >= items.length)
      return;

    const item = items[this.highlightedIndex];
    const form = item.querySelector("form");
    if (form) {
      form.requestSubmit();
    }
  }

  updateAriaActiveDescendant() {
    const items = this.visibleItems;
    if (this.highlightedIndex >= 0 && this.highlightedIndex < items.length) {
      const item = items[this.highlightedIndex];
      this.inputTarget.setAttribute("aria-activedescendant", item.id);
    } else {
      this.inputTarget.removeAttribute("aria-activedescendant");
    }
  }

  get visibleItems() {
    return Array.from(
      this.listTarget.querySelectorAll(".filterable-item"),
    ).filter((item) => item.style.display !== "none");
  }
}
