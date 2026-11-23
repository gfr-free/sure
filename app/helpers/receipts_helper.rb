module ReceiptsHelper
  RECEIPT_STATUS_TONES = { reading: :info, open: :warning, linked: :success, dismissed: :neutral }.freeze

  def receipt_status_pill(receipt)
    status = receipt.extraction_failed? && receipt.status == :open ? :failed : receipt.status
    tone = status == :failed ? :error : RECEIPT_STATUS_TONES.fetch(status)
    render DS::Pill.new(label: t("receipts.status.#{status}"), tone: tone, marker: false)
  end

  def receipt_file_icon(receipt)
    receipt.image? ? "image" : "file-text"
  end

  def receipt_amount(receipt)
    money = receipt.amount_money
    money ? format_money(money) : t("receipts.unknown")
  end

  # The amount as a number input value, padded to the currency's precision
  # ("5.80", "1200" for JPY) but never rounded, so saving the form unchanged
  # keeps a stored "12.3456". Always with a dot, whatever the user's locale.
  def receipt_amount_input_value(receipt)
    return nil if receipt.amount.nil?

    # Built from the decimal string: %f would go through a float and change
    # large amounts ("123456789012345.1234" to "...1250").
    whole, fraction = receipt.amount.to_d.to_s("F").split(".")
    fraction = fraction.to_s.sub(/0+\z/, "").ljust(receipt_currency_precision(receipt), "0")
    fraction.empty? ? whole : "#{whole}.#{fraction}"
  end

  # "Read from PDF text, 90% sure" next to a field the reader filled; nothing for manual edits.
  def receipt_field_hint(receipt, field)
    source = receipt.field_source(field)
    return if source.blank? || source == "manual"

    confidence = receipt.field_confidence(field).to_f
    t("receipts.show.field_hint", source: t("receipts.sources.#{source}"), confidence: number_to_percentage(confidence * 100, precision: 0))
  end

  private
    def receipt_currency_precision(receipt)
      Money::Currency.new(receipt.currency.presence || receipt.family.currency).default_precision.to_i
    rescue Money::Currency::UnknownCurrencyError
      2
    end
end
