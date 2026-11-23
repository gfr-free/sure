# frozen_string_literal: true

# Text recognition (Tesseract) for photos and for PDFs without a text layer,
# read with Receipt::TextParser. Without Tesseract on this server such receipts
# keep their fields blank, and the notice "ocr_unavailable" says why.
class Receipt::Extraction::Stages::Ocr < Receipt::Extraction::Stage
  # A PDF with fewer letters and digits than this in its text layer is a scan.
  MIN_PDF_TEXT_CHARACTERS = 20

  def self.position
    40
  end

  def self.source
    "ocr"
  end

  # Photos always; PDFs only when their text layer is (almost) empty, since a
  # rendered copy of real text reads no better than the text itself.
  def applicable?
    receipt.image? || (receipt.pdf? && extraction.pdf_text.to_s.scan(/[[:alnum:]]/).size < MIN_PDF_TEXT_CHARACTERS)
  end

  def read
    unless available?
      extraction.notice!("ocr_unavailable")
      return nil
    end

    result = recognize
    reading = text_reading(result.text)
    return nil if reading.nil?

    reading.with(fields: reading.fields.transform_values { |value| value.merge(confidence: scaled(value[:confidence], result)) })
  end

  private
    def available?
      receipt.image? ? Receipt::Ocr.available?(locale: locale) : Receipt::Ocr.pdf_available?(locale: locale)
    end

    def recognize
      ocr = Receipt::Ocr.new(locale: locale)
      if receipt.image?
        ocr.read_image(extraction.content, content_type: receipt.content_type)
      else
        ocr.read_pdf(extraction.content, max_pages: Receipt::Extraction::MAX_PDF_PAGES)
      end
    rescue Receipt::Ocr::Error => e
      # The code only, never text read from the receipt.
      DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt##{receipt.id}: text recognition failed: #{e.code}",
                            source: "receipt_ocr", family: receipt.family, user_id: receipt.uploaded_by_id)
      raise Receipt::Extraction::Error, e.code
    end

    def locale
      receipt.uploaded_by&.locale.presence || receipt.family.locale
    end

    # A misread character can turn a right-looking amount into a wrong one, so a
    # field read from a blurry photo counts as less certain than the rule alone.
    def scaled(confidence, result)
      (confidence * result.confidence.clamp(0.5, 1.0)).round(2)
    end
end
