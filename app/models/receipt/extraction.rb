# frozen_string_literal: true

# Reads a receipt's header data in stages, from the most reliable source to the
# least. Each stage fills only the fields the earlier ones left blank, and the run
# stops once amount and date are both known.
#
# The stages: the text layer of a PDF, then AI (`extract_receipt`) when the
# uploader has AI on and amount or date is still missing or unsure. Without AI,
# images keep their fields blank and the user fills them in by hand.
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
  # Parsing and masking run on at most this much text per page, so a page full
  # of text cannot make them slow. A receipt's header and total fit well within.
  MAX_PAGE_TEXT_LENGTH = 20_000
  REQUIRED_FIELDS = %w[amount date].freeze
  # A field read with this confidence or less (a guessed merchant, the family
  # currency as a fallback) may be replaced by the AI's reading.
  UNSURE_CONFIDENCE = 0.5

  attr_reader :receipt

  def initialize(receipt)
    @receipt = receipt
  end

  def run
    fields = {}
    texts = []

    stages.each do |stage|
      text = stage[:read].call
      next if text.blank?

      texts << text
      parsed = Receipt::TextParser.parse(text, currency_hint: receipt.family.currency, merchant_names: merchant_names)
      parsed.each do |field, value|
        value = value.merge(value: Receipt::TextParser.mask(value[:value])) if field == "merchant_name"
        fields[field] ||= value.merge(source: stage[:source])
      end
      break if REQUIRED_FIELDS.all? { |field| fields.key?(field) }
    end

    if REQUIRED_FIELDS.any? { |field| unsure?(fields[field]) } && ai_available?
      ai_fields(texts.join("\n")).each do |field, value|
        fields[field] = value if unsure?(fields[field])
      end
    end

    Result.new(fields: fields, raw_text: Receipt::TextParser.mask(texts.join("\n")).first(MAX_RAW_TEXT_LENGTH).presence)
  end

  private
    def stages
      [
        { source: "pdf_text", read: -> { pdf_text if receipt.pdf? } }
      ]
    end

    def pdf_text
      Pdf::TextExtractor.pages(content, max_pages: MAX_PDF_PAGES).map { _1.first(MAX_PAGE_TEXT_LENGTH) }.join("\n")
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::EncryptedPDFError
      raise Error, "unreadable_pdf"
    end

    def unsure?(value)
      value.nil? || value[:confidence].to_f <= UNSURE_CONFIDENCE
    end

    def ai_available?
      receipt.uploaded_by.present? && Ai.available?(:extract_receipt, family: receipt.family, user: receipt.uploaded_by)
    end

    # The AI's reading, checked against the text the earlier stages found. It is
    # best effort: any failure leaves the fields as they were, and the user fills
    # them in by hand.
    def ai_fields(text)
      generation = Ai::Generations::ExtractReceipt.new(attachment: receipt.file, family: receipt.family, user: receipt.uploaded_by,
                                                       text: Receipt::TextParser.mask(text).presence)
      result = Ai::CallContext.job("receipt_extraction:#{receipt.id}") { generation.call }
      # No route can read this kind of file (a photo for a text-only model): nothing to report.
      return {} if result.unavailable?
      return Receipt::AiReading.new(result.value!, text:, currency_hint: receipt.family.currency).fields if result.success?

      capture_ai_failure(result.error.class.name)
      {}
    rescue StandardError => e
      capture_ai_failure(e.class.name)
      {}
    end

    # Names the error class only, never text read from the receipt.
    def capture_ai_failure(reason)
      DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt##{receipt.id}: AI reading failed: #{reason}",
                            source: "receipt_extraction", family: receipt.family, user_id: receipt.uploaded_by_id)
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
