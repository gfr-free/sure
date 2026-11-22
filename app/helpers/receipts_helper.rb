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

  # The amount as a number input value at the currency's precision ("5.80",
  # "1200" for JPY), always with a dot, whatever the user's locale.
  def receipt_amount_input_value(receipt)
    return nil if receipt.amount.nil?

    format("%.#{receipt_currency_precision(receipt)}f", receipt.amount)
  end

  def receipt_amount_step(receipt)
    precision = receipt_currency_precision(receipt)
    precision.zero? ? "1" : "0.#{'0' * (precision - 1)}1"
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
