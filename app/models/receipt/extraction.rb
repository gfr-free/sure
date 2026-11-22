# frozen_string_literal: true

# Reads a receipt's header data in stages, from the most reliable source to the
# least. Each stage fills only the fields the earlier ones left blank, and the run
# stops once amount and date are both known.
#
# 1. The text layer of a PDF.
# 2. Text recognition (Tesseract) for photos and for PDFs without a text layer,
#    when it is installed. Without it, such receipts keep their fields blank and
#    the user fills them in by hand.
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
  # A PDF with fewer letters and digits than this in its text layer is a scan.
  MIN_PDF_TEXT_CHARACTERS = 20

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
        fields[field] ||= value.merge(source: stage[:source], confidence: scaled_confidence(value[:confidence], stage))
      end
      break if REQUIRED_FIELDS.all? { |field| fields.key?(field) }
    end

    Result.new(fields: fields, raw_text: Receipt::TextParser.mask(texts.join("\n")).first(MAX_RAW_TEXT_LENGTH).presence)
  end

  private
    def stages
      [
        { source: "pdf_text", read: -> { pdf_text if receipt.pdf? } },
        { source: "ocr", read: -> { ocr_text if ocr? } }
      ]
    end

    def pdf_text
      return @pdf_text if defined?(@pdf_text)

      @pdf_text = Pdf::TextExtractor.pages(content, max_pages: MAX_PDF_PAGES).join("\n")
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::EncryptedPDFError
      raise Error, "unreadable_pdf"
    end

    # Photos always; PDFs only when their text layer is (almost) empty, since a
    # rendered copy of real text reads no better than the text itself.
    def ocr?
      return false unless Receipt::Ocr.available?
      return true if receipt.image?

      receipt.pdf? && pdf_text.to_s.scan(/[[:alnum:]]/).size < MIN_PDF_TEXT_CHARACTERS
    end

    def ocr_text
      ocr = Receipt::Ocr.new(locale: receipt.uploaded_by&.locale.presence || receipt.family.locale)
      @ocr_result = receipt.image? ? ocr.read_image(content) : ocr.read_pdf(content, max_pages: MAX_PDF_PAGES)
      @ocr_result.text
    rescue Receipt::Ocr::Error => e
      raise Error, e.code
    end

    # A misread character can turn a right-looking amount into a wrong one, so a
    # field read from a blurry photo counts as less certain than the rule alone.
    def scaled_confidence(confidence, stage)
      return confidence unless stage[:source] == "ocr" && @ocr_result

      (confidence * @ocr_result.confidence.clamp(0.5, 1.0)).round(2)
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
