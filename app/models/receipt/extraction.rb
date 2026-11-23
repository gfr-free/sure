# frozen_string_literal: true

# Reads a receipt's header data in stages, from the most reliable source to the
# least. A stage is a Receipt::Extraction::Stage subclass in
# Receipt::Extraction::Stages; the stages run in the order of their `position`,
# and each fills only the fields the earlier ones left blank. A stage runs only
# while it is wanted, by default while a field of Receipt::FIELDS is missing.
#
# A stage that fails after earlier ones already read something does not fail
# the run: their fields are kept and the error code is kept as a notice. Only a
# failure before anything was read fails the receipt.
class Receipt::Extraction
  class Error < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  # `notice` says why fields may be missing although the read finished (e.g. a
  # stage could not run on this server). `attributes` are further receipt
  # columns the stages set.
  Result = Data.define(:fields, :raw_text, :notice, :attributes) do
    def initialize(fields:, raw_text:, notice: nil, attributes: {})
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

  attr_reader :receipt, :fields, :texts

  def self.stages
    Rails.autoloaders.main.eager_load_namespace(Stages)
    Stages.constants.map { |name| Stages.const_get(name) }
          .select { |stage| stage.is_a?(Class) && stage < Stage }
          .sort_by(&:position)
  end

  def initialize(receipt)
    @receipt = receipt
  end

  def run
    @fields = {}
    @texts = []
    @settled = []
    @notice = nil
    stages = self.class.stages
    attributes = stages.map(&:default_attributes).reduce({}, :merge)

    stages.each do |stage_class|
      stage = stage_class.new(self)
      reading = read(stage)
      next if reading.nil?

      @texts << reading.text if reading.text.present?
      attributes.merge!(reading.attributes)
      merge(reading.fields, stage)
      @settled |= reading.settles
    end

    Result.new(fields: fields, raw_text: Receipt::TextParser.mask(texts.join("\n")).first(MAX_RAW_TEXT_LENGTH).presence,
               notice: @notice, attributes: attributes)
  end

  # Fields no stage has read or settled yet.
  def missing_fields
    Receipt::FIELDS - fields.keys - @settled
  end

  def settled?(field)
    @settled.include?(field.to_s)
  end

  # For a stage to say why it could not read the file; the first notice is kept.
  def notice!(code)
    @notice ||= code
  end

  def content
    @content ||= receipt.file.download
  rescue ActiveStorage::FileNotFoundError
    raise Error, "file_missing"
  end

  # The text layer of a PDF, read once for every stage that needs it.
  def pdf_text
    return @pdf_text if defined?(@pdf_text)

    @pdf_text = Pdf::TextExtractor.pages(content, max_pages: MAX_PDF_PAGES).map { _1.first(MAX_PAGE_TEXT_LENGTH) }.join("\n")
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::EncryptedPDFError
    raise Error, "unreadable_pdf"
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

  private
    def read(stage)
      return nil unless stage.wanted?

      stage.read
    rescue Error => e
      raise if fields.empty?

      notice!(e.code)
      nil
    end

    def merge(read, stage)
      # The currency belongs to the amount: a stage that supplies the amount and
      # its currency also decides the currency an earlier stage guessed.
      fields.delete("currency") if read.key?("amount") && read.key?("currency") && !fields.key?("amount") && !settled?("amount")

      read.each do |field, value|
        next if settled?(field)
        next if fields.key?(field) && !stage.replaces?(field, fields[field])

        value = value.merge(value: Receipt::TextParser.mask(value[:value])) if field == "merchant_name"
        fields[field] = value.merge(source: stage.source)
      end
    end
end
