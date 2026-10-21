import { Controller } from "@hotwired/stimulus";
import replaceUrl from "utils/replace_url";

// Searches and filters the rules list in the browser, and folds rule groups.
// Each rule row carries its search text and filter values as data-rule-*
// attributes. While a search or filter is active, groups with matches are
// shown open and dragging is off: with rules hidden, a drop could land
// somewhere the user cannot see.
export default class extends Controller {
  static targets = [
    "input",
    "select",
    "rule",
    "group",
    "handle",
    "dragHint",
    "empty",
    "reset",
  ];

  connect() {
    this.#hydrateFromUrl();
    this.filter();
  }

  disconnect() {
    clearTimeout(this.urlSyncTimer);
  }

  filter() {
    const rawQuery = this.inputTarget.value.trim();
    const query = this.#normalize(rawQuery);
    const filters = this.#selectedFilters();
    const filtering =
      rawQuery.length > 0 || Object.values(filters).some((value) => value);
    let visibleCount = 0;

    this.ruleTargets.forEach((rule) => {
      const show = !filtering || this.#matches(rule, rawQuery, query, filters);
      rule.classList.toggle("hidden", !show);
      if (show) visibleCount++;
    });

    this.groupTargets.forEach((group) => {
      const hasMatch = this.ruleTargets.some(
        (rule) => group.contains(rule) && !rule.classList.contains("hidden"),
      );
      group.classList.toggle("hidden", filtering && !hasMatch);
      this.#setGroupOpen(group, filtering || !this.#isCollapsed(group));
    });

    this.filtering = filtering;
    this.emptyTarget.classList.toggle("hidden", !filtering || visibleCount > 0);
    this.dragHintTarget.classList.toggle("hidden", !filtering);
    this.resetTarget.classList.toggle("hidden", !filtering);
    this.#setDraggable(!filtering);
    this.#scheduleUrlSync();
  }

  reset() {
    this.inputTarget.value = "";
    this.selectTargets.forEach((select) => {
      select.value = "";
    });
    this.filter();
  }

  // Folding is remembered per device. While filtering, groups are shown open
  // for their matches, so a toggle then only changes the view.
  toggleGroup(event) {
    const group = this.groupTargets.find((target) =>
      target.contains(event.currentTarget),
    );
    if (!group) return;

    const open = event.currentTarget.getAttribute("aria-expanded") !== "true";
    if (!this.filtering) this.#storeCollapsed(group, !open);
    this.#setGroupOpen(group, open);
  }

  #matches(rule, rawQuery, query, filters) {
    // A query that normalizes to nothing (e.g. a lone combining mark) matches
    // no rule rather than every rule.
    if (rawQuery.length > 0) {
      if (query.length === 0) return false;
      if (!this.#normalize(rule.dataset.ruleSearch || "").includes(query)) {
        return false;
      }
    }

    if (
      filters.status &&
      rule.dataset.ruleActive !== String(filters.status === "active")
    ) {
      return false;
    }

    return (
      this.#listIncludes(rule.dataset.ruleActions, filters.action) &&
      this.#listIncludes(rule.dataset.ruleConditions, filters.condition) &&
      this.#listIncludes(rule.dataset.ruleAccounts, filters.account) &&
      (!filters.group || rule.dataset.ruleGroup === filters.group)
    );
  }

  #listIncludes(list, value) {
    if (!value) return true;
    return (list || "").split(" ").includes(value);
  }

  #selectedFilters() {
    return Object.fromEntries(
      this.selectTargets.map((select) => [
        select.dataset.filterParam,
        select.value,
      ]),
    );
  }

  #setGroupOpen(group, open) {
    const toggle = group.querySelector("[data-rules-filter-group-toggle]");
    const body = group.querySelector("[data-rules-filter-group-body]");
    const chevron = group.querySelector("[data-rules-filter-group-chevron]");

    toggle?.setAttribute("aria-expanded", String(open));
    body?.classList.toggle("hidden", !open);
    chevron?.classList.toggle("-rotate-90", !open);
  }

  #setDraggable(enabled) {
    this.element
      .querySelectorAll("[draggable]")
      .forEach((item) => {
        item.setAttribute("draggable", String(enabled));
      });
    this.handleTargets.forEach((handle) => {
      handle.classList.toggle("invisible", !enabled);
      handle.disabled = !enabled;
    });
  }

  #storageKey(group) {
    return `rule-group-collapsed:${group.dataset.groupId}`;
  }

  // Storage can be unavailable (private mode, blocked site data); the groups
  // then simply start open.
  #isCollapsed(group) {
    try {
      return localStorage.getItem(this.#storageKey(group)) === "true";
    } catch {
      return false;
    }
  }

  #storeCollapsed(group, collapsed) {
    try {
      if (collapsed) {
        localStorage.setItem(this.#storageKey(group), "true");
      } else {
        localStorage.removeItem(this.#storageKey(group));
      }
    } catch {
      // Not remembered; the fold still applies to this page.
    }
  }

  // Case- and diacritic-insensitive, as in list_filter_controller.
  #normalize(value) {
    return value
      .normalize("NFD")
      .replace(/\p{Mark}/gu, "")
      .toLowerCase();
  }

  #fields() {
    return [this.inputTarget, ...this.selectTargets];
  }

  #hydrateFromUrl() {
    const params = new URLSearchParams(window.location.search);

    this.#fields().forEach((field) => {
      const value = params.get(field.dataset.filterParam);
      if (value === null) return;
      if (
        field.tagName === "SELECT" &&
        ![...field.options].some((option) => option.value === value)
      ) {
        return;
      }
      field.value = value;
    });
  }

  // Debounced so a typing burst updates the URL once.
  #scheduleUrlSync() {
    clearTimeout(this.urlSyncTimer);
    this.urlSyncTimer = setTimeout(() => this.#syncUrl(), 200);
  }

  #syncUrl() {
    const params = new URLSearchParams(window.location.search);

    this.#fields().forEach((field) => {
      const value = field.value.trim();
      if (value) {
        params.set(field.dataset.filterParam, value);
      } else {
        params.delete(field.dataset.filterParam);
      }
    });

    const query = params.toString();
    const url = query
      ? `${window.location.pathname}?${query}`
      : window.location.pathname;
    if (url !== `${window.location.pathname}${window.location.search}`) {
      replaceUrl(url);
    }
  }
}
