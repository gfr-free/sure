# frozen_string_literal: true

# The e-invoice XML: a plain XML file (XRechnung) or the one embedded in a
# ZUGFeRD/Factur-X PDF. An e-invoice is the invoice itself, so once one is read,
# an amount it leaves out (a credit note's) is not guessed from the PDF text
# printed from it.
class Receipt::Extraction::Stages::EInvoice < Receipt::Extraction::Stage
  def self.position
    10
  end

  def self.source
    "einvoice"
  end

  def applicable?
    receipt.xml? || receipt.pdf?
  end

  # The file is downloaded outside the rescue: a storage error must fail the
  # extraction, not leave an XML receipt "completed" with nothing read.
  def read
    fields = parse(extraction.content)
    return nil if fields.blank?

    Reading.new(fields: fields, settles: %w[amount])
  end

  private
    # A PDF the e-invoice reader trips over may still have a readable text
    # layer, so an unexpected parser error is logged and the next stage runs.
    def parse(data)
      receipt.xml? ? Receipt::EInvoice.parse(data) : Receipt::EInvoice.from_pdf(data)
    rescue StandardError => e
      DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt##{receipt.id}: e-invoice stage failed: #{e.class}",
                            source: "receipt_extraction", family: receipt.family, user_id: receipt.uploaded_by_id,
                            metadata: { stage: "einvoice" })
      nil
    end
end
