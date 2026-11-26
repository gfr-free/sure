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
  // toLowerCase, not toLocaleLowerCase: in a Turkish browser the latter
  // turns "I" into a dotless "ı", so "Income" would not equal "income".
  return String(value ?? "").trim().normalize("NFC").toLowerCase();
}

export function namesExactly(element, rawQuery) {
  const query = exactName(rawQuery);
  if (query.length === 0) return false;

  return searchNames(element).some((name) => exactName(name) === query);
}

// One Enter rule for every picker's search box:
// 1. Enter never submits the surrounding form (callers preventDefault).
// 2. While a "create" row shows, Enter creates (callers check that first).
// 3. Otherwise it picks enterMatch: the exact name, else the name that is
//    equal once accents and case are folded, else the first visible row.
// 4. An empty search picks nothing.
// The Enter that ends an IME composition only commits the characters;
// Safari reports it with keyCode 229 and isComposing already false.
export function isConfirmingEnter(event) {
  return event.key === "Enter" && !event.isComposing && event.keyCode !== 229;
}

export function enterMatch(visibleRows, rawQuery) {
  if (!hasSearchQuery(rawQuery)) return null;

  // A row marked data-filter-context is only shown around a hit (a parent
  // category above its matching subcategory) and is never the Enter target.
  const hits = visibleRows.filter((row) => !row.hasAttribute?.("data-filter-context"));
  const folded = normalizeSearchText(String(rawQuery).trim());
  return (
    hits.find((row) => namesExactly(row, rawQuery)) ??
    hits.find((row) =>
      searchNames(row).some((name) => normalizeSearchText(name).trim() === folded),
    ) ??
    hits[0] ??
    null
  );
}
