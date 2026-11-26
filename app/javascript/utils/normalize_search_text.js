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
  return value
    .normalize("NFD")
    .replace(/\p{Mark}/gu, "")
    .replaceAll("_", " ")
    .toLowerCase();
}

// Whether two names are the same once accents on Latin letters are
// ignored, so Enter on "epicerie fine" can pick the existing "Épicerie
// fine". Marks on other scripts stay: without them Japanese dakuten, Indic
// vowel signs or the Cyrillic "й" spell a different word.
export function sameNameIgnoringLatinAccents(a, b) {
  return foldLatinAccents(a) === foldLatinAccents(b);
}

function foldLatinAccents(value) {
  return value
    .normalize("NFD")
    .replace(/(\p{Script=Latin})\p{Mark}+/gu, "$1")
    .normalize("NFC")
    .toLowerCase();
}
