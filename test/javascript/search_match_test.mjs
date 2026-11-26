import { describe, it } from "node:test"
import assert from "node:assert/strict"

import {
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
