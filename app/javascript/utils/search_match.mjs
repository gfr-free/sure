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

function filterTerms(element) {
  const { filterTerms } = element.dataset;
  if (!filterTerms) return [];

  try {
    const terms = JSON.parse(filterTerms);
    return Array.isArray(terms)
      ? terms.filter((term) => typeof term === "string" && term.length > 0)
      : [];
  } catch {
    // A malformed attribute leaves the label as the only name.
    return [];
  }
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

// Whether the query names the row exactly, which decides whether "create"
// is offered. Only case is ignored, so "Cafe" can still be created next to
// "Café" even though the search shows both.
export function namesExactly(element, rawQuery) {
  const query = String(rawQuery ?? "").trim().toLocaleLowerCase();
  if (query.length === 0) return false;

  return searchNames(element).some(
    (name) => name.toLocaleLowerCase() === query,
  );
}
