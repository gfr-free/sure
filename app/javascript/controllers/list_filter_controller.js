import { Controller } from "@hotwired/stimulus";
import {
  expandTreeMatches,
  firstSearchHit,
  hasSearchQuery,
  matchesSearch,
  treeRow,
} from "utils/search_match";

// Filters a list by the shared search rule in utils/search_match: each
// .filterable-item is found by its data-filter-name and data-filter-terms.
export default class extends Controller {
  static targets = ["input", "list", "emptyMessage", "recentSection"];
  static values = { wholeGroups: Boolean };

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

    if (this.hasRecentSectionTarget) {
      this.recentSectionTarget.classList.toggle(
        "hidden",
        hasSearchQuery(rawFilterValue),
      );
    }

    if (this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.add("hidden");
    }

    // Rows shown only because a relative matched are marked, so keyboard
    // selection can start at the row the search actually found.
    const show = (item, shouldDisplay, direct = shouldDisplay) => {
      item.style.display = shouldDisplay ? "" : "none";
      item.toggleAttribute("data-filter-context", shouldDisplay && !direct);
      if (shouldDisplay) noMatchFound = false;
    };

    // A match on a category also shows its subcategories and its parent
    // (expandTreeMatches). The Recent section repeats ids from the main list
    // and stays out of that.
    const treeItems = [];
    const treeRows = [];

    items.forEach((item) => {
      if (recentItems.has(item)) {
        // The section itself is hidden while searching; hide its rows too, so
        // arrow keys don't land on a row nobody can see.
        show(
          item,
          !hasSearchQuery(rawFilterValue) &&
            matchesSearch(item, rawFilterValue),
        );
      } else {
        treeItems.push(item);
        treeRows.push(treeRow(item, matchesSearch(item, rawFilterValue)));
      }
    });

    expandTreeMatches(treeRows, { wholeGroups: this.wholeGroupsValue }).forEach(
      (visible, index) => {
        show(treeItems[index], visible, treeRows[index].direct);
      },
    );

    if (noMatchFound && this.hasEmptyMessageTarget) {
      this.emptyMessageTarget.classList.remove("hidden");
    }

    this.highlightedIndex = -1;
    this.clearHighlights();
    this.updateAriaActiveDescendant();
  }

  handleKeydown(event) {
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
    this.highlightedIndex =
      this.highlightedIndex < 0
        ? this.firstHitIndex(items)
        : Math.min(this.highlightedIndex + 1, items.length - 1);
    this.highlightItem(items[this.highlightedIndex]);
    this.updateAriaActiveDescendant();
  }

  highlightPrevious() {
    const items = this.visibleItems;
    if (items.length === 0) return;

    this.clearHighlights();
    this.highlightedIndex =
      this.highlightedIndex < 0
        ? this.firstHitIndex(items)
        : Math.max(this.highlightedIndex - 1, 0);
    this.highlightItem(items[this.highlightedIndex]);
    this.updateAriaActiveDescendant();
  }

  // From the search box the arrow keys start at the first row the search
  // found, not at a parent shown above it only for context.
  firstHitIndex(items) {
    return Math.max(items.indexOf(firstSearchHit(items)), 0);
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
