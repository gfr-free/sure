# frozen_string_literal: true

# Turns the `extract_receipt` answer into receipt fields, in the shape
# Receipt::TextParser returns them. Values a receipt can't hold (a refund total,
# a date in the future, an unknown currency) are dropped.
#
# A model's wrong answer often looks right, so amount and date are checked
# against the text the earlier stages read: found there, they count as more
# certain; missing from it, as less. Without text (a photo), they keep a middle
# confidence the user sees next to the field.
class Receipt::AiReading
  SOURCE = "ai"
  CONFIDENCE = 0.6
  CONFIRMED_CONFIDENCE = 0.8
  CONTRADICTED_CONFIDENCE = 0.4

  def initialize(value, text: nil)
    @value = value.to_h.with_indifferent_access
    @text = text.to_s
  end

  # Returns { "field" => { value:, confidence:, source: "ai" } }.
  def fields
    {
      "merchant_name" => merchant_name&.then { { value: _1, confidence: CONFIDENCE } },
      "amount" => amount&.then { { value: _1, confidence: checked_confidence(amount_variants(_1)) } },
      "date" => date&.then { { value: _1, confidence: checked_confidence(date_variants(_1)) } },
      "currency" => currency&.then { { value: _1, confidence: CONFIDENCE } }
    }.compact.transform_values { _1.merge(source: SOURCE) }
  end

  private
    attr_reader :value, :text

    def merchant_name
      value[:merchant_name].to_s.squish.presence&.truncate(200, omission: "")
    end

    def amount
      total = Transaction::ReceiptExtraction::ReceiptExtraction.decimal_or_nil(value[:total])
      total if total&.positive?
    end

    def date
      parsed = Date.iso8601(value[:date].to_s)
      parsed if parsed <= Date.current && parsed >= Date.current - Receipt::TextParser::MAX_AGE
    rescue Date::Error
      nil
    end

    def currency
      code = value[:currency].to_s.strip.upcase
      Money::Currency.new(code).iso_code if code.match?(/\A[A-Z]{3}\z/)
    rescue Money::Currency::UnknownCurrencyError
      nil
    end

    def checked_confidence(variants)
      return CONFIDENCE if text.blank?

      variants.any? { text.include?(_1) } ? CONFIRMED_CONFIDENCE : CONTRADICTED_CONFIDENCE
    end

    # 1234.5 as printed on receipts: "1234.50", "1234,50", "1.234,50", "1,234.50".
    def amount_variants(amount)
      plain = format("%.2f", amount)
      whole, cents = plain.split(".")
      grouped = whole.reverse.scan(/\d{1,3}/).join(",").reverse
      [ plain, "#{whole},#{cents}", "#{grouped.tr(',', '.')},#{cents}", "#{grouped}.#{cents}" ].uniq
    end

    def date_variants(date)
      [ date.iso8601, date.strftime("%d.%m.%Y"), date.strftime("%d.%m.%y"), date.strftime("%d/%m/%Y"),
        date.strftime("%m/%d/%Y"), date.strftime("%-d.%-m.%Y") ].uniq
    end
end
