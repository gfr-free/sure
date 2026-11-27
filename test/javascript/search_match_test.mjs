import { describe, it } from "node:test"
import assert from "node:assert/strict"

import {
  enterMatch,
  exactMatch,
  exactName,
  isComposing,
  hasSearchQuery,
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
