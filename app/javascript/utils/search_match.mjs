// One search rule for every picker list (list-filter, category-select).
// A row is searched by its shown label (data-filter-name) plus any extra
// names in data-filter-terms (a JSON array), e.g. a default category's
// stored name next to its translated one.

// Case- and diacritic-insensitive: "prestecs" should match "Prèstecs".
// NFD splits each accented char into base char + combining mark, then
// \p{Mark} strips the marks, so both sides compare on bare base characters.
// Not \p{Diacritic}: that property is broader than combining marks — it
// also covers standalone characters like "^", "`", the middot, and
// modifier letters (e.g. the Hawaiian ʻokina) — so a query of just one of
// those would normalize to "", and "".includes() matches everything,
// silently showing every row instead of filtering.
// Underscores read as spaces, so an identifier typed as "America/New_York"
// finds its label "America/New York".
export function normalizeSearchText(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/\p{Mark}/gu, "")
    .replaceAll("_", " ")
    .toLowerCase();
}

// Parsed once per attribute value: filtering runs on every keystroke.
const parsedTerms = new WeakMap();

function filterTerms(element) {
  const { filterTerms } = element.dataset;
  if (!filterTerms) return [];

  const cached = parsedTerms.get(element);
  if (cached?.source === filterTerms) return cached.terms;

  let terms = [];
  try {
    const parsed = JSON.parse(filterTerms);
    if (Array.isArray(parsed)) {
      terms = parsed.filter((term) => typeof term === "string" && term.length > 0);
    }
  } catch {
    // A malformed attribute leaves the label as the only name.
  }

  parsedTerms.set(element, { source: filterTerms, terms });
  return terms;
}

// Every name a row can be found by, as written (not normalized).
export function searchNames(element) {
  const { filterName } = element.dataset;
  const names = filterName ? [filterName, ...filterTerms(element)] : filterTerms(element);
  return [...new Set(names)];
}

// The name that identifies the row: the first of data-filter-terms (for a
// category its stored name, see CategoriesHelper#category_search_data), else
// the label.
export function primarySearchName(element) {
  return filterTerms(element)[0] ?? element.dataset.filterName ?? "";
}

// Whether the query, once normalized, still has something to search for.
export function hasSearchQuery(rawQuery) {
  return normalizeSearchText(String(rawQuery ?? "").trim()).length > 0;
}

// Only a genuinely empty query means "show everything". A non-empty query
// that normalizes away to "" (e.g. a lone combining mark) must still match
// nothing — "".includes("") is true, so without this split it would show
// every row instead of filtering.
// Surrounding spaces are ignored, so a query of only spaces counts as empty.
// Each word must appear in the same name, in any order: "drink food" finds
// "Food & Drink".
export function matchesSearch(element, rawQuery) {
  const trimmed = String(rawQuery ?? "").trim();
  if (trimmed.length === 0) return true;

  const words = normalizeSearchText(trimmed).split(/\s+/).filter(Boolean);
  if (words.length === 0) return false;

  return searchNames(element).some((name) => {
    const text = normalizeSearchText(name);
    return words.every((word) => text.includes(word));
  });
}

// Whether a typed name is an existing one: exact but for case and Unicode
// form, so "Café" can sit next to "Cafe" yet a pasted decomposed "Café"
// still counts as the existing one. This decides whether "create" is offered.
export function exactName(value) {
  return String(value ?? "").trim().normalize("NFC").toLocaleLowerCase();
}

export function namesExactly(element, rawQuery) {
  const query = exactName(rawQuery);
  if (query.length === 0) return false;

  return searchNames(element).some((name) => exactName(name) === query);
}

// Widens matches to a two-level tree (categories and their subcategories).
// Each row is { id, parentId, direct }, where `direct` says whether the row
// matched by its own names (matchesSearch). A row stays visible when it
// matched itself, when its parent matched (searching "Car" keeps "Fuel"
// under "Car"), or when one of its children matched (searching "Fuel" keeps
// "Car" above it for context). Rows without an id or parentId only ever
// match directly.
//
// With wholeGroups, a matching subcategory shows its whole group (parent and
// siblings). Checkbox lists need that: checking a parent there checks all of
// its subcategories, so none of them may be hidden while the parent shows.
export function expandTreeMatches(rows, { wholeGroups = false } = {}) {
  const matchedIds = new Set();
  const parentsOfMatches = new Set();

  for (const row of rows) {
    if (!row.direct) continue;
    if (row.id) matchedIds.add(row.id);
    if (row.parentId) {
      parentsOfMatches.add(row.parentId);
      if (wholeGroups) matchedIds.add(row.parentId);
    }
  }

  return rows.map(
    (row) =>
      row.direct ||
      Boolean(row.parentId && matchedIds.has(row.parentId)) ||
      Boolean(row.id && parentsOfMatches.has(row.id)),
  );
}

// The tree position of a row rendered with CategoriesHelper#category_search_data.
export function treeRow(element, direct) {
  return {
    id: element.dataset.filterId,
    parentId: element.dataset.filterParentId,
    direct,
  };
}
