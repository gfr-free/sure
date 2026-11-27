import { describe, it } from "node:test"
import assert from "node:assert/strict"

import {
  displaySortKey,
  enterMatch,
  exactName,
  hasSearchQuery,
  isConfirmingEnter,
  matchesSearch,
  namesExactly,
  normalizeSearchText,
  primarySearchName,
  searchNames,
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

describe("enterMatch", () => {
  const zedExtra = row("Zed Extra")
  const zed = row("Zéd")
  const cafe = row("Cafe")
  const cafeAccent = row("Café")

  it("picks nothing for an empty query", () => {
    assert.equal(enterMatch([zedExtra, zed], ""), null)
    assert.equal(enterMatch([zedExtra, zed], "   "), null)
  })

  it("prefers the exact name over the first row", () => {
    assert.equal(enterMatch([cafe, cafeAccent], "café"), cafeAccent)
    assert.equal(enterMatch([cafeAccent, cafe], "cafe"), cafe)
  })

  it("then the name equal once accents are folded", () => {
    assert.equal(enterMatch([zedExtra, zed], "zed"), zed)
  })

  it("then the first visible row", () => {
    assert.equal(enterMatch([zedExtra, zed], "ze"), zedExtra)
  })

  it("can skip the first-visible fallback", () => {
    assert.equal(enterMatch([zedExtra, zed], "ze", { firstVisible: false }), null)
    assert.equal(enterMatch([zedExtra, zed], "zed", { firstVisible: false }), zed)
  })

  it("never falls back to the blank row", () => {
    const none = { ...row("Uncategorized"), hasAttribute: (name) => name === "data-filter-blank" }
    const utilities = row("Utilities")
    assert.equal(enterMatch([none, utilities], "u"), utilities)
    assert.equal(enterMatch([none], "u"), null)
    assert.equal(enterMatch([none, utilities], "uncategorized"), none)
  })

  it("matches a stored name too", () => {
    assert.equal(enterMatch([row("Other"), translated], "food & drink"), translated)
  })

  it("has nothing to pick in an empty list", () => {
    assert.equal(enterMatch([], "zed"), null)
  })

  it("prefers the stored name when two rows show the same label", () => {
    const translatedDefault = row("Lebensmittel", ["Groceries", "Lebensmittel"])
    const custom = row("Lebensmittel", ["Lebensmittel"])
    assert.equal(enterMatch([translatedDefault, custom], "Lebensmittel"), custom)
  })

  it("folds accents on Latin letters only", () => {
    const burger = row("ハンバーガー")
    assert.equal(enterMatch([burger, row("バン")], "ハン"), burger)
    const ivanExtra = row("Иван Extra")
    assert.equal(enterMatch([ivanExtra, row("Йван")], "иван"), ivanExtra)
  })

  it("never picks a row shown only as context for a hit", () => {
    const parent = { ...row("Food & Drink"), hasAttribute: (name) => name === "data-filter-context" }
    const child = { ...row("Restaurants"), hasAttribute: () => false }
    assert.equal(enterMatch([parent, child], "Restaur"), child)
  })
})

describe("displaySortKey", () => {
  it("folds Latin accents only and keeps underscores", () => {
    assert.equal(displaySortKey("Épargne"), "epargne")
    assert.equal(displaySortKey("Йогурт"), "йогурт")
    assert.ok(displaySortKey("A B") < displaySortKey("A_A"))
  })
})
