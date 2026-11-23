# frozen_string_literal: true

# Reads merchant, date, total and currency from the text of a receipt or invoice
# with fixed rules, without AI.
#
# - Total: the amount on a line with a total label ("Summe", "Gesamtbetrag",
#   "Zu zahlen", "Total", "Amount due"). Stronger labels win; among equals the
#   last one does, since totals sit at the end. Subtotals, tax and change lines
#   are skipped. A second line with the same amount (the payment line) raises
#   the confidence.
# - Date: the first plausible date, preferring one on a line with a date label
#   or a time of day. Slash dates are month first for USD, taken from the
#   currency printed on the receipt, else from the hint. Dates in the future
#   or more than two years back are ignored.
# - Merchant: a known merchant name in the first lines, else the first line that
#   reads like a name.
# - Currency: the total's own symbol or code, else one printed next to another
#   amount, else the hint.
#
# Labels cover German, English, French, Italian, Spanish and Dutch.
class Receipt::TextParser
  # Like the statement parser's amounts, but receipts often print totals of a
  # thousand or more without a grouping separator ("1234,56").
  AMOUNT_NUMBER = /(?<![\d.,])(?:\d{1,3}(?:[.,'\u00A0\u202F ]\d{3})+|\d+)[.,]\d{2}(?![\d]|[.,\/-]\d)/
  CURRENCY_MARK = AccountStatement::TextMetadataParser::CURRENCY_MARK
  AMOUNT_PATTERN = Regexp.union(
    /(?<prefix_currency>#{CURRENCY_MARK})\p{Blank}*[-+]?(?<prefix_number>#{AMOUNT_NUMBER})/,
    /(?<suffix_number>#{AMOUNT_NUMBER})(?:\p{Blank}*(?<suffix_currency>#{CURRENCY_MARK}))?/
  )
  CURRENCY_SYMBOLS = { "€" => "EUR", "£" => "GBP" }.freeze
  WHOLE_AMOUNT = /\A[\s:=]*(?:(?<prefix_currency>#{CURRENCY_MARK})\p{Blank}*)?(?<number>\d{1,3}(?:[,.'\u00A0\u202F ]\d{3})+|\d+)(?![\d.,]*\d)(?!\p{Blank}+\d)(?:\p{Blank}*(?<suffix_currency>#{CURRENCY_MARK}))?/

  # Weight 3 names the amount to pay, 2 a plain total, 1 a payment line.
  TOTAL_LABELS = {
    3 => [ "zu zahlen", "gesamtbetrag", "rechnungsbetrag", "endbetrag", "zahlbetrag", "amount due", "total due",
           "grand total", "balance due", "net à payer", "montant dû", "totale da pagare", "importe total", "te betalen" ],
    2 => [ "summe", "gesamt", "total", "totale", "montant", "importe", "totaal", "bedrag" ],
    1 => [ "bar", "ec-karte", "ec karte", "girocard", "kartenzahlung", "karte", "visa", "mastercard", "maestro",
           "card", "cash", "paid", "bezahlt", "betrag" ]
  }.freeze
  EXCLUDED_LABELS = [
    "zwischensumme", "subtotal", "sub-total", "sous-total", "netto", "net", "mwst", "ust", "steuer", "tax", "vat",
    "tva", "iva", "btw", "rückgeld", "rueckgeld", "wechselgeld", "gegeben", "change", "rendu", "resto", "trinkgeld",
    "tip", "pfand"
  ].freeze

  # A discount line can carry a strong label ("Rabatt auf Gesamtbetrag"), so it
  # is skipped whatever the label's weight, unless the total comes after it
  # ("Gesamtbetrag nach Rabatt").
  # Savings lines ("TOTAL SAVINGS 3.00") are printed after the total and count alike.
  DISCOUNT_LABELS = [ "rabatt", "nachlass", "discount", "remise", "sconto", "descuento", "korting", "savings", "saved",
                      "ersparnis", "gespart", "économie", "économies", "risparmio", "ahorro", "besparing" ].freeze
  AFTER_DISCOUNT = /(?:nach|after|abzgl|abzüglich|less|minus|inkl|incl)\.?\s*\z/i

  # "inkl. MwSt" or "incl. VAT" on a total line names the total, not the tax.
  INCLUDING = /(?:inkl|incl|including|inclus|compris|ttc|iva incluida)\.?\s*\z/i
  # "(incl. VAT 2.00 EUR)": the tax inside is never the total.
  INCLUSION_CLAUSE = /\([^()]*(?<![[:alpha:]])(?:inkl|incl|including|inclus|compris|iva incluida)(?![[:alpha:]])[^()]*\)/i
  # Slash dates read month first for these currencies' receipts.
  MONTH_FIRST_CURRENCIES = %w[USD].freeze

  DATE_LABELS = /\b(?:datum|date|rechnungsdatum|belegdatum|invoice date|data|fecha|datum)\b/i
  TIME_OF_DAY = /\b(?:[01]?\d|2[0-3]):[0-5]\d\b/
  DATE_FORMATS = [
    /(?<!\d)(?<year>\d{4})-(?<month>\d{1,2})-(?<day>\d{1,2})(?!\d)/,
    %r{(?<!\d)(?<day>\d{1,2})(?<separator>[./-])(?<month>\d{1,2})[./-](?<year>\d{4})(?!\d)},
    %r{(?<!\d)(?<day>\d{1,2})(?<separator>[./])(?<month>\d{1,2})[./](?<year>\d{2})(?![\d.,/])}
  ].freeze
  MAX_AGE = 2.years
  MAX_AMOUNT = Receipt::MAX_AMOUNT
  MERCHANT_LINES = 8

  # Card numbers and IBANs never need to be stored in full.
  # A line break, with blanks around it, may split either one where the PDF wraps it.
  WRAP = /[ \t\u00A0\u202F]*\r?\n[ \t\u00A0\u202F]*/
  CARD_NUMBER = /(?<!\d)(?:\d(?:[ \u00A0\u202F-]|#{WRAP})?){12,18}\d(?!\d)/
  IBAN = /\b[A-Z]{2}\d{2}(?:(?:[ \u00A0\u202F]|#{WRAP})?[A-Z0-9]){11,30}\b/i

  def self.parse(text, currency_hint: nil, merchant_names: [])
    new(text, currency_hint:, merchant_names:).parse
  end

  # Today on the server may still be yesterday where the receipt was printed.
  def self.plausible_date?(date)
    date <= Date.current + 1 && date >= Date.current - MAX_AGE
  end

  def self.mask(text)
    text.to_s
      .gsub(IBAN) { |match| "#{'*' * 4}#{match.delete(" \t\u00A0\u202F\r\n")[-4..]}" }
      .gsub(CARD_NUMBER) { |match| "#{'*' * 4}#{match.delete(" \t\u00A0\u202F\r\n-")[-4..]}" }
  end

  def initialize(text, currency_hint: nil, merchant_names: [])
    @text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    @lines = @text.lines.map(&:strip)
    @currency_hint = currency_hint.to_s.upcase.presence
    @merchant_names = merchant_names
  end

  # Every amount printed in the text, as positive decimals.
  def amounts
    amounts_in(@text).map { _1[:value] }
  end

  # Every plausible date in the text, read the way #parse reads them.
  def dates
    parse_dates.map { _1[:date] }
  end

  # Returns { "field" => { value:, confidence: } } for each field it could read.
  def parse
    fields = {}
    total = parse_total
    # A total of zero (a voided or fully discounted receipt) leaves the amount
    # blank rather than guessing another number.
    if total && total[:value].positive?
      fields["amount"] = { value: total[:value], confidence: total[:confidence] }
    end

    currency = total&.dig(:currency) || any_currency
    @printed_currency = currency
    if currency
      fields["currency"] = { value: currency, confidence: 0.9 }
    elsif @currency_hint && fields["amount"]
      fields["currency"] = { value: @currency_hint, confidence: 0.5 }
    end

    date = parse_date
    fields["date"] = date if date

    merchant = parse_merchant
    fields["merchant_name"] = merchant if merchant

    fields
  end

  private
    def parse_total
      candidates = []
      @lines.each_with_index do |line, index|
        normalized = line.downcase
        weight, label_start, label_end = total_label(normalized)
        next unless weight
        next if weight < 3 && excluded_line?(normalized)
        next if discount_line?(normalized)

        # The first amount after the label ("Total 119.00 EUR (incl. VAT 19.00 EUR)"),
        # skipping an inclusion clause, else one printed before it, else the next line's.
        after_label = line[label_end..].gsub(INCLUSION_CLAUSE, " ")
        before_label = line[0...label_end].gsub(INCLUSION_CLAUSE, " ")
        amount = amounts_in(after_label, keep_zero: true).first || amounts_in(before_label, keep_zero: true).last ||
                 bare_zero(after_label) || whole_amount(after_label, line[0...label_start]) || continuation_amount(index)
        next unless amount

        # "USD TOTAL 12.34": a currency printed just before the label.
        amount = amount.merge(currency: currency_before(line[0...label_start])) if amount[:currency].nil?
        candidates << amount.merge(weight: weight, index: index)
      end

      return fallback_total if candidates.empty?

      best_weight = candidates.map { _1[:weight] }.max
      best = candidates.select { _1[:weight] == best_weight }.max_by { _1[:index] }
      confirmed = candidates.count { _1[:value] == best[:value] } > 1
      best.merge(confidence: confirmed ? 0.9 : 0.7)
    end

    # The strongest label on the line and where it starts and ends.
    def total_label(line)
      TOTAL_LABELS.each do |weight, labels|
        labels.each do |label|
          match = line.match(label_regexp(label))
          return [ weight, match.begin(0), match.end(0) ] if match
        end
      end
      nil
    end

    # A subtotal, tax, change or discount line, unless the word only says what
    # the total includes ("Gesamt inkl. MwSt") or comes after ("Total after discount").
    def excluded_line?(line)
      discount_line?(line) || EXCLUDED_LABELS.any? do |label|
        line.to_enum(:scan, label_regexp(label)).any? do
          !line[0...Regexp.last_match.begin(0)].match?(INCLUDING)
        end
      end
    end

    def discount_line?(line)
      DISCOUNT_LABELS.any? do |label|
        line.to_enum(:scan, label_regexp(label)).any? do
          !line[0...Regexp.last_match.begin(0)].match?(AFTER_DISCOUNT)
        end
      end
    end

    # Without a label, the largest amount is the best guess, but only a guess.
    # Change, tax and subtotal lines are left out here too.
    def fallback_total
      largest = @lines.reject { excluded_line?(_1.downcase) }.flat_map { amounts_in(_1) }.max_by { _1[:value] }
      largest&.merge(confidence: 0.3)
    end

    # "Total 0 EUR": an explicit zero without decimals, so the total does not
    # borrow the next line's amount.
    def bare_zero(text)
      { value: BigDecimal("0"), currency: nil } if text.match?(/\A[\s:=]*0(?![\d.,])/)
    end

    # "TOTAL JPY 1500": a whole number counts as an amount only for a currency
    # without minor units, named on the line or by the hint.
    def whole_amount(text, before_label)
      match = text.match(WHOLE_AMOUNT)
      return nil unless match

      printed = resolve_currency(match[:prefix_currency] || match[:suffix_currency]) || currency_before(before_label)
      currency = printed || @currency_hint
      return nil unless currency && Money::Currency.new(currency).default_precision.to_i.zero?

      value = BigDecimal(match[:number].delete(" ,.'\u00A0\u202F"))
      { value: value, currency: printed } if value < MAX_AMOUNT
    rescue Money::Currency::UnknownCurrencyError, ArgumentError
      nil
    end

    # A label alone on its line takes the next line's amount, unless that line
    # is a tax, subtotal or change line of its own.
    def continuation_amount(index)
      line = next_line(index)
      return nil if excluded_line?(line.downcase)

      amounts_in(line, keep_zero: true).first
    end

    def currency_before(text)
      token = text.to_s[/(?:(?<![[:alpha:]])[A-Z]{3}|[€$£¥])\s*\z/]
      resolve_currency(token.to_s.strip)
    end

    def next_line(index)
      @lines[(index + 1)..].to_a.find(&:present?).to_s
    end

    def label_regexp(label)
      @label_regexps ||= {}
      @label_regexps[label] ||= /(?<![[:alpha:]])#{Regexp.escape(label)}(?![[:alpha:]])/i
    end

    def amounts_in(text, keep_zero: false)
      text.to_s.to_enum(:scan, AMOUNT_PATTERN).filter_map do
        match = Regexp.last_match
        value = parse_amount(match[:prefix_number] || match[:suffix_number])
        next if value.nil? || (value.zero? && !keep_zero)

        { value: value.abs, currency: resolve_currency(match[:prefix_currency] || match[:suffix_currency]) }
      end
    end

    # The last separator is the decimal one: "1.234,56" and "1,234.56".
    def parse_amount(raw)
      digits = raw.to_s.delete(" '  ")
      return nil unless [ ",", "." ].include?(digits[-3])

      value = BigDecimal("#{digits[0...-3].delete('.,')}.#{digits[-2..]}")
      value if value < MAX_AMOUNT
    rescue ArgumentError
      nil
    end

    def resolve_currency(token)
      return nil if token.blank?
      return CURRENCY_SYMBOLS[token] if CURRENCY_SYMBOLS.key?(token)
      return @currency_hint if token == "$" && dollar_hint?

      currency = Money::Currency.new(token)
      currency.iso_code
    rescue Money::Currency::UnknownCurrencyError
      nil
    end

    def dollar_hint?
      @currency_hint.present? && Money::Currency.new(@currency_hint).symbol == "$"
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    # Only a code or symbol printed next to an amount counts, so a word such as
    # "ALL" in "ALL PRICES INCL. VAT" is never read as a currency.
    def any_currency
      amounts_in(@text).filter_map { _1[:currency] }.first
    end

    def parse_date
      found = parse_dates
      return nil if found.empty?

      labelled = found.find { _1[:labelled] }
      pick = labelled || found.first
      { value: pick[:date], confidence: labelled ? 0.9 : 0.6 }
    end

    def parse_dates
      found = []
      @lines.each do |line|
        labelled = line.match?(DATE_LABELS) || line.match?(TIME_OF_DAY)
        in_line = DATE_FORMATS.flat_map do |format|
          line.to_enum(:scan, format).filter_map do
            match = Regexp.last_match
            date = build_date(match)
            { date: date, labelled: labelled, position: match.begin(0) } if date
          end
        end
        # Formats are scanned one after another; keep the order they are printed in.
        found.concat(in_line.sort_by { _1[:position] })
      end
      found
    end

    def build_date(match)
      year = match[:year].to_i
      year += 2000 if year < 100
      day, month = match[:day].to_i, match[:month].to_i
      day, month = month, day if match.names.include?("separator") && match[:separator] == "/" && month_first?
      date = Date.new(year, month, day)
      date if self.class.plausible_date?(date)
    rescue Date::Error
      nil
    end

    # The currency printed on the receipt decides; the family's only when none is.
    def month_first?
      MONTH_FIRST_CURRENCIES.include?(@printed_currency || @currency_hint)
    end

    def parse_merchant
      head = @lines.first(MERCHANT_LINES).reject(&:blank?)

      known = @merchant_names.find do |name|
        next if name.to_s.length < 3

        pattern = /(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i
        head.any? { |line| line.match?(pattern) }
      end
      return { value: known, confidence: 0.8 } if known

      guess = head.find { |line| plausible_name?(line) }
      guess ? { value: guess.truncate(200, omission: ""), confidence: 0.3 } : nil
    end

    def plausible_name?(line)
      letters = line.count("a-zA-ZäöüÄÖÜßéèàçñ")
      letters >= 3 && letters >= line.length / 2 && !line.match?(AMOUNT_PATTERN) && DATE_FORMATS.none? { line.match?(_1) }
    end
end
