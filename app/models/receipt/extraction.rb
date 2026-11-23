# frozen_string_literal: true

# Reads a receipt's header data in stages, from the most reliable source to the
# least. Each stage fills only the fields the earlier ones left blank, and the run
# stops once every field is known.
#
# Stages today: QR codes (photos and PDFs), then the text layer of a PDF. A photo
# without a QR code keeps its fields blank; the user fills them in by hand.
class Receipt::Extraction
  class Error < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  Result = Data.define(:fields, :raw_text, :identifiers) do
    def initialize(fields:, raw_text:, identifiers: [])
      super
    end
  end

  # Raw text is kept for the user to check what was read, not for search, so it
  # is capped.
  MAX_RAW_TEXT_LENGTH = 20_000
  MAX_PDF_PAGES = 5
  # Parsing and masking run on at most this much text per page, so a page full
  # of text cannot make them slow. A receipt's header and total fit well within.
  MAX_PAGE_TEXT_LENGTH = 20_000
  # The merchant of an earlier receipt from the same till or payee was confirmed
  # by the user, so it beats the name printed in a transfer code.
  LEARNED_MERCHANT_CONFIDENCE = 0.95

  attr_reader :receipt

  def initialize(receipt)
    @receipt = receipt
  end

  def run
    fields = {}
    texts = []
    identifiers = []

    stages.each do |stage|
      reading = read_stage(stage, found_fields: fields.any?)
      next if reading.nil?

      texts << reading[:text] if reading[:text].present?
      identifiers.concat(reading[:identifiers].to_a)
      reading[:fields].each do |field, value|
        fields[field] ||= value.merge(source: stage[:source])
      end
      break if Receipt::FIELDS.all? { |field| fields.key?(field) }
    end

    Result.new(fields: fields, raw_text: Receipt::TextParser.mask(texts.join("\n")).first(MAX_RAW_TEXT_LENGTH).presence,
               identifiers: identifiers.uniq)
  end

  private
    # A PDF whose text layer cannot be read still keeps what its QR code gave.
    def read_stage(stage, found_fields:)
      stage[:read].call
    rescue Error => e
      raise unless found_fields && e.code == "unreadable_pdf"

      nil
    end

    def stages
      [
        { source: "qr", read: -> { qr_reading } },
        { source: "pdf_text", read: -> { text_reading(pdf_text) if receipt.pdf? } }
      ]
    end

    # QR contents are not added to the raw text: they hold IBANs and signatures,
    # and the fields read from them are shown anyway.
    def qr_reading
      payloads = Receipt::QrReader.read(content, content_type: receipt.content_type)
      return nil if payloads.empty?

      result = Receipt::QrParser.parse(payloads, timezone: receipt.family.timezone)
      fields = result.fields.dup
      if (merchant = receipt.learned_merchant(result.identifiers))
        fields["merchant_name"] = { value: merchant.name, confidence: LEARNED_MERCHANT_CONFIDENCE }
      end

      { fields: fields, identifiers: result.identifiers }
    rescue Receipt::ExternalCommand::Error => e
      # Without the QR stage the receipt is still read from its text.
      DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt##{receipt.id}: QR stage skipped: #{e.class}",
                            source: "receipt_extraction", family: receipt.family, user_id: receipt.uploaded_by_id)
      nil
    end

    def text_reading(text)
      return nil if text.blank?

      fields = Receipt::TextParser.parse(text, currency_hint: receipt.family.currency, merchant_names: merchant_names)
      if fields["merchant_name"]
        fields["merchant_name"] = fields["merchant_name"].merge(value: Receipt::TextParser.mask(fields["merchant_name"][:value]))
      end

      { text: text, fields: fields }
    end

    def pdf_text
      Pdf::TextExtractor.pages(content, max_pages: MAX_PDF_PAGES).map { _1.first(MAX_PAGE_TEXT_LENGTH) }.join("\n")
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::EncryptedPDFError
      raise Error, "unreadable_pdf"
    end

    def content
      @content ||= receipt.file.download
    rescue ActiveStorage::FileNotFoundError
      raise Error, "file_missing"
    end

    # The family's own merchants plus the provider merchants on its transactions,
    # longest first so "REWE Markt" wins over "REWE".
    def merchant_names
      @merchant_names ||= begin
        family_names = receipt.family.merchants.pluck(:name)
        provider_names = Merchant.where(id: receipt.family.transactions.where.not(merchant_id: nil).select(:merchant_id)).pluck(:name)
        (family_names + provider_names).compact.uniq.sort_by { |name| -name.length }
      end
    end
end
