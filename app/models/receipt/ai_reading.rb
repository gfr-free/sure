# frozen_string_literal: true

# Turns the `extract_receipt` answer into receipt fields, in the shape
# Receipt::TextParser returns them. Values a receipt can't hold (a refund total,
# a total too large to store, a date in the future, an unknown currency) are
# dropped.
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

  def initialize(value, text: nil, currency_hint: nil)
    @value = value.to_h.with_indifferent_access
    @parser = Receipt::TextParser.new(text, currency_hint:) if text.present?
  end

  # Returns { "field" => { value:, confidence:, source: "ai" } }.
  def fields
    {
      "merchant_name" => merchant_name&.then { { value: _1, confidence: CONFIDENCE } },
      "amount" => amount&.then { { value: _1, confidence: checked_confidence(_1, :amounts) } },
      "date" => date&.then { { value: _1, confidence: checked_confidence(_1, :dates) } },
      "currency" => currency&.then { { value: _1, confidence: CONFIDENCE } }
    }.compact.transform_values { _1.merge(source: SOURCE) }
  end

  private
    attr_reader :value, :parser

    def merchant_name
      value[:merchant_name].to_s.squish.presence&.truncate(200, omission: "")
    end

    def amount
      total = Transaction::ReceiptExtraction::ReceiptExtraction.decimal_or_nil(value[:total])
      total if total&.positive? && total < Receipt::MAX_AMOUNT
    end

    def date
      parsed = Date.iso8601(value[:date].to_s)
      parsed if Receipt::TextParser.plausible_date?(parsed)
    rescue Date::Error
      nil
    end

    def currency
      code = value[:currency].to_s.strip.upcase
      Money::Currency.new(code).iso_code if code.match?(/\A[A-Z]{3}\z/)
    rescue Money::Currency::UnknownCurrencyError
      nil
    end

    # Compares values, not strings, so "2.00" isn't found inside "12.00" and a
    # date matches however the receipt prints it.
    def checked_confidence(read, found)
      return CONFIDENCE if parser.nil?

      parser.public_send(found).include?(read) ? CONFIRMED_CONFIDENCE : CONTRADICTED_CONFIDENCE
    end
end
