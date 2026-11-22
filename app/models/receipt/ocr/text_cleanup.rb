# frozen_string_literal: true

# Repairs the misreadings Tesseract typically makes in amounts on receipts, so
# the rule parser finds them:
#
# - a letter O read for a zero inside a number: "12,3O" → "12,30"
# - a space after the decimal separator: "SUMME EUR 12, 30" → "SUMME EUR 12,30"
#
# Only tokens shaped like an amount with two decimals are touched; words stay
# as they are. A split amount is joined only at the end of a line that names a
# currency or a total, so lists such as "Tisch 3, 12" stay apart.
module Receipt::Ocr::TextCleanup
  # Digits or O's, a separator, then two digits or O's, with at least one real
  # digit before the separator.
  LETTER_O_AMOUNT = /(?<![[:alpha:]\d])(?=[0-9Oo]*\d)[0-9Oo]{1,7}[.,][0-9Oo]{2}(?![[:alnum:]])/
  SPLIT_DECIMALS = /(?<=\d)([.,]) (?=\d{2}\s*(?:€|£|\$|[A-Z]{3})?\s*\z)/
  CURRENCY = /€|£|\$|\b(?:EUR|USD|GBP|CHF)\b/i

  def self.call(text)
    text.to_s.each_line.map { |line| clean_line(line) }.join
  end

  def self.clean_line(line)
    line = line.sub(SPLIT_DECIMALS, '\1') if amount_context?(line)
    line.gsub(LETTER_O_AMOUNT) { |amount| amount.tr("Oo", "00") }
  end

  def self.amount_context?(line)
    return true if line.match?(CURRENCY)

    normalized = line.downcase
    Receipt::TextParser::TOTAL_LABELS.values.flatten.any? do |label|
      normalized.match?(/(?<![[:alpha:]])#{Regexp.escape(label)}(?![[:alpha:]])/)
    end
  end
  private_class_method :clean_line, :amount_context?
end
