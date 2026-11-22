# frozen_string_literal: true

# Reads a receipt's header data in stages, from the most reliable source to the
# least. Each stage fills only the fields the earlier ones left blank, and the run
# stops once amount and date are both known.
#
# Stages today: the e-invoice XML (a plain XML file or the one embedded in a
# ZUGFeRD/Factur-X PDF), then the text layer of a PDF. Images keep their fields
# blank until a stage that can read them exists; the user fills them in by hand.
class Receipt::Extraction
  class Error < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  Result = Data.define(:fields, :raw_text)

  # Raw text is kept for the user to check what was read, not for search, so it
  # is capped.
  MAX_RAW_TEXT_LENGTH = 20_000
  MAX_PDF_PAGES = 5
  REQUIRED_FIELDS = %w[amount date].freeze
  # An e-invoice is the invoice itself: once one is read, an amount it leaves
  # out (a credit note's) must not be guessed from the PDF text printed from it.
  SETTLED_BY_SOURCE = { "einvoice" => %w[amount] }.freeze

  attr_reader :receipt

  def initialize(receipt)
    @receipt = receipt
  end

  def run
    fields = {}
    texts = []

    settled = []

    stages.each do |source, read|
      parsed, text = read.call
      texts << text if text.present?
      parsed.to_h.each do |field, value|
        next if settled.include?(field)

        value = value.merge(value: Receipt::TextParser.mask(value[:value])) if field == "merchant_name"
        fields[field] ||= value.merge(source: source)
      end
      settled |= SETTLED_BY_SOURCE.fetch(source, []) if parsed.present?
      break if REQUIRED_FIELDS.all? { |field| fields.key?(field) || settled.include?(field) }
    end

    Result.new(fields: fields, raw_text: Receipt::TextParser.mask(texts.join("\n")).first(MAX_RAW_TEXT_LENGTH).presence)
  end

  private
    # Each stage returns the fields it read and, when it read text, that text.
    def stages
      {
        "einvoice" => -> { [ einvoice_fields ] },
        "pdf_text" => -> { text_fields(pdf_text) if receipt.pdf? }
      }
    end

    # A PDF the e-invoice reader trips over may still have a readable text
    # layer, so an unexpected parser error is logged and the next stage runs.
    # The file is downloaded first: a storage error must fail the extraction,
    # not leave an XML receipt "completed" with nothing read.
    def einvoice_fields
      return unless receipt.xml? || receipt.pdf?

      read_einvoice(content)
    end

    def read_einvoice(data)
      receipt.xml? ? Receipt::EInvoice.parse(data) : Receipt::EInvoice.from_pdf(data)
    rescue StandardError => e
      DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt##{receipt.id}: e-invoice stage failed: #{e.class}",
                            source: "receipt_extraction", family: receipt.family, user_id: receipt.uploaded_by_id,
                            metadata: { stage: "einvoice" })
      nil
    end

    def text_fields(text)
      return if text.blank?

      [ Receipt::TextParser.parse(text, currency_hint: receipt.family.currency, merchant_names: merchant_names), text ]
    end

    def pdf_text
      Pdf::TextExtractor.pages(content, max_pages: MAX_PDF_PAGES).join("\n")
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
