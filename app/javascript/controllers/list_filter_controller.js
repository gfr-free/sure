import { Controller } from "@hotwired/stimulus";
import {
  enterFallback,
  enterMatch,
  expandTreeMatches,
  firstSearchHit,
  hasSearchQuery,
  isComposing,
  isConfirmingEnter,
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

    // A row a Turbo stream replaces comes back without its filter state, so
    // the current search is applied to the new rows. Only to those rows: the
    // empty message and highlights belong to filter() and other controllers.
    this.rowObserver = new MutationObserver((mutations) =>
      this.#filterAddedRows(mutations),
    );
    this.rowObserver.observe(this.listTarget, { childList: true, subtree: true });
  }

  disconnect() {
    this.rowObserver?.disconnect();
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
        show(item, !searching && matchesSearch(item, rawFilterValue));
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

  #filterAddedRows(mutations) {
    const query = this.inputTarget.value;
    const searching = hasSearchQuery(query);

    for (const { addedNodes } of mutations) {
      for (const node of addedNodes) {
        if (!(node instanceof Element)) continue;
        const rows = node.matches(".filterable-item")
          ? [node]
          : node.querySelectorAll(".filterable-item");
        for (const row of rows) {
          const inRecent =
            this.hasRecentSectionTarget &&
            this.recentSectionTarget.contains(row);
          if ((searching && inRecent) || !matchesSearch(row, query)) {
            row.style.display = "none";
          }
        }
      }
    }
  }

  handleKeydown(event) {
    if (isComposing(event)) return;

    if (event.key === "ArrowDown") {
      event.preventDefault();
      this.highlightNext();
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      this.highlightPrevious();
    } else if (isConfirmingEnter(event)) {
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

  // A row picked with the arrow keys wins. Otherwise the shared Enter rule
  // (utils/search_match): the row the search names; with none, a visible
  // create row is left to its own handler, else the first visible row.
  selectHighlighted() {
    const items = this.visibleItems;
    const highlighted = items[this.highlightedIndex];
    if (this.highlightedIndex >= 0 && highlighted) {
      this.activate(highlighted, { toggle: true });
      return;
    }

    // A hidden list (the quick create's parent picker covers it) has nothing to pick.
    if (this.listTarget.classList.contains("hidden")) return;

    const query = this.inputTarget.value;
    if (!hasSearchQuery(query)) return;

    const existing = enterMatch(items, query);
    if (!existing && this.createRowShown) return;

    const match = existing ?? enterFallback(items);
    if (match) this.activate(match, { toggle: false });
  }

  // A row either submits its own form or carries a checkbox (merchant merge).
  // A typed Enter only adds: it leaves an applied row (data-list-filter-applied,
  // e.g. a tag already on the transaction) and a checked box alone; removing
  // takes an explicit pick.
  activate(item, { toggle }) {
    if (!toggle && item.dataset.listFilterApplied === "true") return;

    const form = item.querySelector("form");
    if (form) {
      // Until the response redraws the row, a second Enter must not toggle
      // the same row back off.
      if (!toggle) {
        item.dataset.listFilterApplied = "true";
        // A failed request leaves the row as it was, so Enter can retry.
        form.addEventListener(
          "turbo:submit-end",
          (event) => {
            if (!event.detail.success) delete item.dataset.listFilterApplied;
          },
          { once: true },
        );
        // Tells the server the pick came from the search box: it only adds
        // (a retry cannot take a tag off) and keeps focus there (the tag menu
        // re-renders the row without autofocus).
        const marker = document.createElement("input");
        marker.type = "hidden";
        marker.name = "from_search";
        marker.value = "1";
        form.append(marker);
        form.requestSubmit();
        marker.remove();
        return;
      }
      form.requestSubmit();
      return;
    }

    const checkbox = item.querySelector("input[type='checkbox']");
    if (checkbox && (toggle || !checkbox.checked)) checkbox.click();
  }

  get createRowShown() {
    const row = this.element.querySelector("[data-list-filter-create]");
    return Boolean(row && !row.classList.contains("hidden"));
  }

  updateAriaActiveDescendant() {
    const items = this.visibleItems;
    if (this.highlightedIndex >= 0 && this.highlightedIndex < items.length) {
      const item = items[this.highlightedIndex];
      // A row without an id (currency list, merchant merge) cannot be named.
      if (item.id) {
        this.inputTarget.setAttribute("aria-activedescendant", item.id);
      } else {
        this.inputTarget.removeAttribute("aria-activedescendant");
      }
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
