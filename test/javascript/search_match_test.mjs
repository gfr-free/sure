import test, { describe, it } from "node:test"
import assert from "node:assert/strict"

import {
  displaySortKey,
  enterFallback,
  enterMatch,
  enterTarget,
  exactMatch,
  exactName,
  expandTreeMatches,
  firstSearchHit,
  isComposing,
  hasSearchQuery,
  isSearchHit,
  isConfirmingEnter,
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
  it("ignores the browser locale", () => {
    // Simulate a Turkish browser, where "I" lowercases to a dotless "ı".
    const original = String.prototype.toLocaleLowerCase
    String.prototype.toLocaleLowerCase = function () {
      return original.call(this, "tr")
    }
    try {
      assert.equal(exactName("Income"), exactName("income"))
    } finally {
      String.prototype.toLocaleLowerCase = original
    }
  })

  it("treats composed and decomposed accents as the same name", () => {
    assert.equal(exactName("Cafe\u0301"), exactName("Café"))
    assert.notEqual(exactName("Cafe"), exactName("Café"))
  })

  it("compares the same way whatever the browser's locale", () => {
    const original = String.prototype.toLocaleLowerCase
    String.prototype.toLocaleLowerCase = function () {
      return original.call(this, "tr")
    }
    try {
      assert.equal(exactName("Income"), exactName("income"))
    } finally {
      String.prototype.toLocaleLowerCase = original
    }
  })
})

describe("exactMatch", () => {
  it("prefers the row whose stored name the query is", () => {
    const custom = row("Restaurants & Bars", ["Restaurants & Bars"])
    assert.equal(exactMatch([translated, custom], "restaurants & bars"), custom)
    assert.equal(exactMatch([translated], "Restaurants & Bars"), translated)
    assert.equal(exactMatch([translated], "Restaurants"), undefined)
    assert.equal(exactMatch([translated], " "), undefined)
  })
})

describe("enterMatch", () => {
  it("takes the exact name, else the only Latin-accent match", () => {
    const epicerie = row("Épicerie fine")
    const pet = row("Pet Supplies")
    assert.equal(enterMatch([pet, translated], "food & drink"), translated)
    assert.equal(enterMatch([pet, epicerie], "epicerie fine"), epicerie)
    assert.equal(enterMatch([pet, epicerie], "pet"), undefined)
  })

  it("gives no answer when several rows differ only in accents", () => {
    assert.equal(enterMatch([row("Résumé"), row("Resumé")], "resume"), undefined)
  })

  it("keeps marks outside Latin script", () => {
    assert.equal(enterMatch([row("ハンバーガー")], "ハンハーカー"), undefined)
  })
})

describe("isComposing", () => {
  it("recognises an IME composition", () => {
    assert.equal(isComposing({ isComposing: true, keyCode: 13 }), true)
    assert.equal(isComposing({ isComposing: false, keyCode: 229 }), true)
    assert.equal(isComposing({ isComposing: false, keyCode: 13 }), false)
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

describe("isConfirmingEnter", () => {
  it("confirms a plain Enter", () => {
    assert.equal(isConfirmingEnter({ key: "Enter", isComposing: false, keyCode: 13 }), true)
  })

  it("leaves the Enter that ends an IME composition alone", () => {
    assert.equal(isConfirmingEnter({ key: "Enter", isComposing: true, keyCode: 13 }), false)
    // Safari: composition already over, but keyCode still 229.
    assert.equal(isConfirmingEnter({ key: "Enter", isComposing: false, keyCode: 229 }), false)
  })

  it("ignores other keys", () => {
    assert.equal(isConfirmingEnter({ key: "a", isComposing: false, keyCode: 65 }), false)
  })
})

describe("enterTarget", () => {
  const zedExtra = row("Zed Extra")
  const zed = row("Zéd")
  const cafe = row("Cafe")
  const cafeAccent = row("Café")

  it("picks nothing for an empty query", () => {
    assert.equal(enterTarget([zedExtra, zed], ""), undefined)
    assert.equal(enterTarget([zedExtra, zed], "   "), undefined)
  })

  it("prefers the exact name over the first row", () => {
    assert.equal(enterTarget([cafe, cafeAccent], "café"), cafeAccent)
    assert.equal(enterTarget([cafeAccent, cafe], "cafe"), cafe)
  })

  it("then the name equal once accents are folded", () => {
    assert.equal(enterTarget([zedExtra, zed], "zed"), zed)
  })

  it("then the first visible row", () => {
    assert.equal(enterTarget([zedExtra, zed], "ze"), zedExtra)
  })

  it("can skip the first-visible fallback", () => {
    assert.equal(enterTarget([zedExtra, zed], "ze", { firstVisible: false }), undefined)
    assert.equal(enterTarget([zedExtra, zed], "zed", { firstVisible: false }), zed)
  })

  it("never falls back to the blank row", () => {
    const none = { ...row("Uncategorized"), hasAttribute: (name) => name === "data-filter-blank" }
    const utilities = row("Utilities")
    assert.equal(enterTarget([none, utilities], "u"), utilities)
    assert.equal(enterTarget([none], "u"), undefined)
    assert.equal(enterTarget([none, utilities], "uncategorized"), none)
  })

  it("matches a stored name too", () => {
    assert.equal(enterTarget([row("Other"), translated], "food & drink"), translated)
  })

  it("has nothing to pick in an empty list", () => {
    assert.equal(enterTarget([], "zed"), undefined)
  })

  it("prefers the stored name when two rows show the same label", () => {
    const translatedDefault = row("Lebensmittel", ["Groceries", "Lebensmittel"])
    const custom = row("Lebensmittel", ["Lebensmittel"])
    assert.equal(enterTarget([translatedDefault, custom], "Lebensmittel"), custom)
  })

  it("folds accents on Latin letters only", () => {
    const burger = row("ハンバーガー")
    assert.equal(enterTarget([burger, row("バン")], "ハン"), burger)
    const ivanExtra = row("Иван Extra")
    assert.equal(enterTarget([ivanExtra, row("Йван")], "иван"), ivanExtra)
  })

  it("leaves the blank row out while a create row shows", () => {
    const none = { ...row("None"), hasAttribute: (name) => name === "data-filter-blank" }
    assert.equal(enterMatch([none], "none"), none)
    assert.equal(enterMatch([none], "none", { blank: false }), undefined)
  })

  it("enterMatch alone gives no answer for a partial name", () => {
    assert.equal(enterMatch([zedExtra, zed], "ze"), undefined)
    assert.equal(enterFallback([zedExtra, zed]), zedExtra)
  })

  it("never picks a row shown only as context for a hit", () => {
    const parent = { ...row("Food & Drink"), hasAttribute: (name) => name === "data-filter-context" }
    const child = { ...row("Restaurants"), hasAttribute: () => false }
    assert.equal(enterTarget([parent, child], "Restaur"), child)
  })
})

describe("displaySortKey", () => {
  it("folds Latin accents only and keeps underscores", () => {
    assert.equal(displaySortKey("Épargne"), "epargne")
    assert.equal(displaySortKey("Йогурт"), "йогурт")
    assert.ok(displaySortKey("A B") < displaySortKey("A_A"))
  })
})
