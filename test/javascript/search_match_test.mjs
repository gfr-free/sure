import test, { describe, it } from "node:test"
import assert from "node:assert/strict"

import {
  exactName,
  expandTreeMatches,
  firstSearchHit,
  hasSearchQuery,
  isSearchHit,
  matchesSearch,
  namesExactly,
  normalizeSearchText,
  primarySearchName,
  searchNames,
  treeRow,
} from "../../app/javascript/utils/search_match.mjs"

// A picker row as CategoriesHelper#category_search_data renders it: the
// shown label plus every name it may be typed as, stored name first.
const row = (filterName, terms) => ({
  dataset: terms === undefined
    ? { filterName }
    : { filterName, filterTerms: JSON.stringify(terms) },
})

// German UI: the default category stored as "Food & Drink" shows translated.
const translated = row("Restaurants & Bars", ["Food & Drink", "Restaurants & Bars"])

describe("normalizeSearchText", () => {
  it("ignores case, accents and underscores", () => {
    assert.equal(normalizeSearchText("Prèstecs"), "prestecs")
    assert.equal(normalizeSearchText("America/New_York"), "america/new york")
  })
})

describe("matchesSearch", () => {
  it("shows every row for an empty or blank query", () => {
    assert.equal(matchesSearch(translated, ""), true)
    assert.equal(matchesSearch(translated, "   "), true)
  })

  it("finds a row by its shown and by its stored name", () => {
    assert.equal(matchesSearch(translated, "bars"), true)
    assert.equal(matchesSearch(translated, "drink"), true)
    assert.equal(matchesSearch(translated, "rent"), false)
  })

  it("needs every word in the same name, in any order", () => {
    assert.equal(matchesSearch(translated, "drink food"), true)
    assert.equal(matchesSearch(translated, "food  &  drink"), true)
    assert.equal(matchesSearch(translated, "food bars"), false)
  })

  it("ignores accents on both sides", () => {
    assert.equal(matchesSearch(row("Café"), "cafe"), true)
    assert.equal(matchesSearch(row("Cafe"), "café"), true)
  })

  it("matches nothing for a query that normalizes away", () => {
    assert.equal(matchesSearch(translated, "́"), false)
  })

  it("falls back to the label alone for rows without terms", () => {
    assert.equal(matchesSearch(row("Groceries"), "groc"), true)
    assert.equal(matchesSearch({ dataset: { filterName: "x", filterTerms: "not json" } }, "x"), true)
  })
})

describe("namesExactly", () => {
  it("is true for any name typed in full, ignoring case only", () => {
    assert.equal(namesExactly(translated, "restaurants & bars"), true)
    assert.equal(namesExactly(translated, " FOOD & DRINK "), true)
    assert.equal(namesExactly(translated, "Food"), false)
    assert.equal(namesExactly(row("Café"), "Cafe"), false)
    assert.equal(namesExactly(translated, ""), false)
  })
})

describe("exactName", () => {
  it("treats composed and decomposed accents as the same name", () => {
    assert.equal(exactName("Cafe\u0301"), exactName("Café"))
    assert.notEqual(exactName("Cafe"), exactName("Café"))
  })
})

describe("primarySearchName", () => {
  it("is the stored name when the row has terms, else the label", () => {
    assert.equal(primarySearchName(translated), "Food & Drink")
    assert.equal(primarySearchName(row("Groceries")), "Groceries")
  })
})

describe("searchNames", () => {
  it("lists each name once", () => {
    assert.deepEqual(searchNames(row("Food & Drink", ["Food & Drink"])), ["Food & Drink"])
  })
})

describe("hasSearchQuery", () => {
  it("is false for blank or vanishing queries", () => {
    assert.equal(hasSearchQuery(""), false)
    assert.equal(hasSearchQuery("  "), false)
    assert.equal(hasSearchQuery("́"), false)
    assert.equal(hasSearchQuery("a"), true)
  })
})


const rows = (directIds) => [
  { id: "car", parentId: undefined, direct: directIds.includes("car") },
  { id: "fuel", parentId: "car", direct: directIds.includes("fuel") },
  { id: "repairs", parentId: "car", direct: directIds.includes("repairs") },
  { id: "food", parentId: undefined, direct: directIds.includes("food") },
  { id: "groceries", parentId: "food", direct: directIds.includes("groceries") },
];

test("a matching parent keeps all of its subcategories visible", () => {
  assert.deepEqual(expandTreeMatches(rows(["car"])), [true, true, true, false, false]);
});

test("a matching subcategory keeps its parent visible but not its siblings", () => {
  assert.deepEqual(expandTreeMatches(rows(["fuel"])), [true, true, false, false, false]);
});

test("matches in different groups expand independently", () => {
  assert.deepEqual(expandTreeMatches(rows(["car", "groceries"])), [true, true, true, true, true]);
});

test("no match hides everything", () => {
  assert.deepEqual(expandTreeMatches(rows([])), [false, false, false, false, false]);
});

test("rows without ids only match on their own text", () => {
  const flat = [
    { id: undefined, parentId: undefined, direct: true },
    { id: "", parentId: "", direct: false },
  ];
  assert.deepEqual(expandTreeMatches(flat), [true, false]);
});

test("a subcategory whose parent is not in the list still matches on its own", () => {
  const orphan = [{ id: "fuel", parentId: "car", direct: true }];
  assert.deepEqual(expandTreeMatches(orphan), [true]);
});

test("wholeGroups shows a matching subcategory's parent and siblings", () => {
  assert.deepEqual(
    expandTreeMatches(rows(["fuel"]), { wholeGroups: true }),
    [true, true, true, false, false],
  );
});

test("treeRow reads the id and parent id category_search_data renders", () => {
  const element = { dataset: { filterId: "fuel", filterParentId: "car" } };
  assert.deepEqual(treeRow(element, true), { id: "fuel", parentId: "car", direct: true });
});

test("rows marked data-filter-context are not search hits", () => {
  const el = (context) => ({ hasAttribute: (name) => context && name === "data-filter-context" });
  const parent = el(true);
  const child = el(false);
  assert.equal(isSearchHit(parent), false);
  assert.equal(isSearchHit(child), true);
  assert.equal(firstSearchHit([parent, child]), child);
  assert.equal(firstSearchHit([parent]), undefined);
});
