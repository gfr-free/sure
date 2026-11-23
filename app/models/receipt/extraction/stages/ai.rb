# frozen_string_literal: true

# The AI reading (`extract_receipt`), last and optional: it runs only when the
# uploader has AI on and amount or date is still missing or unsure, and it may
# replace a field the earlier stages were unsure about. It is best effort: any
# failure leaves the fields as they were, and the user fills them in by hand.
class Receipt::Extraction::Stages::Ai < Receipt::Extraction::Stage
  REQUIRED_FIELDS = %w[amount date].freeze
  # A field read with this confidence or less (a guessed merchant, the family
  # currency as a fallback) may be replaced by the AI's reading.
  UNSURE_CONFIDENCE = 0.5

  def self.position
    50
  end

  def self.source
    Receipt::AiReading::SOURCE
  end

  def applicable?
    receipt.uploaded_by.present? && Ai.available?(:extract_receipt, family: receipt.family, user: receipt.uploaded_by)
  end

  def wanted?
    REQUIRED_FIELDS.any? { |field| unsure?(fields[field]) } && applicable?
  end

  def replaces?(_field, earlier)
    unsure?(earlier)
  end

  # The AI's reading, checked against the text the earlier stages found.
  def read
    text = extraction.texts.join("\n")
    generation = Ai::Generations::ExtractReceipt.new(attachment: receipt.file, family: receipt.family, user: receipt.uploaded_by,
                                                     text: Receipt::TextParser.mask(text).presence)
    result = Ai::CallContext.job("receipt_extraction:#{receipt.id}") { generation.call }
    # No route can read this kind of file (a photo for a text-only model): nothing to report.
    return nil if result.unavailable?
    return Reading.new(fields: Receipt::AiReading.new(result.value!, text:, currency_hint: receipt.family.currency).fields) if result.success?

    capture_failure(result.error.class.name)
    nil
  rescue StandardError => e
    capture_failure(e.class.name)
    nil
  end

  private
    def unsure?(value)
      value.nil? || value[:confidence].to_f <= UNSURE_CONFIDENCE
    end

    # Names the error class only, never text read from the receipt.
    def capture_failure(reason)
      DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt##{receipt.id}: AI reading failed: #{reason}",
                            source: "receipt_extraction", family: receipt.family, user_id: receipt.uploaded_by_id)
    end
end
