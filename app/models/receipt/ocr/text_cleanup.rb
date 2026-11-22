# frozen_string_literal: true

# Repairs the misreadings Tesseract typically makes in amounts on receipts, so
# the rule parser finds them:
#
# - a letter O read for a zero inside a number: "12,3O" → "12,30"
# - a space after the decimal separator: "12, 30" → "12,30"
#
# Only tokens shaped like an amount with two decimals are touched; words stay
# as they are.
module Receipt::Ocr::TextCleanup
  # Digits or O's, a separator, then two digits or O's, with at least one real
  # digit before the separator.
  LETTER_O_AMOUNT = /(?<![[:alpha:]\d])(?=[0-9Oo]*\d)[0-9Oo]{1,7}[.,][0-9Oo]{2}(?![[:alnum:]])/
  SPLIT_DECIMALS = /(?<=\d)([.,]) (?=\d{2}(?![\d.,]))/

  def self.call(text)
    text.to_s
      .gsub(SPLIT_DECIMALS, '\1')
      .gsub(LETTER_O_AMOUNT) { |amount| amount.tr("Oo", "00") }
  end
end
