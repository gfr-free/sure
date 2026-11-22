# frozen_string_literal: true

# Reads the header data of an electronic invoice, without OCR or AI:
#
# - CII: ZUGFeRD 2, Factur-X and XRechnung in CII syntax (also the older ZUGFeRD 1)
# - UBL: XRechnung and Peppol invoices and credit notes
#
# The XML is the invoice itself, not a picture of it, so its values are certain.
# A hybrid PDF (ZUGFeRD, Factur-X) carries the same XML as an embedded file.
#
# Amounts are only read for invoices: Sure records receipts as expenses, so a
# credit note keeps its merchant, date and number, and the user decides what to
# do with the amount.
class Receipt::EInvoice
  MAX_SIZE = 5.megabytes
  # Bounds the work on a PDF that embeds many large XML files.
  MAX_PDF_FILES_TRIED = 3
  CONFIDENCE = 1.0

  # Names the standards give the XML inside a hybrid PDF; other XML files are
  # tried after these.
  PDF_ATTACHMENT_NAMES = %w[factur-x.xml zugferd-invoice.xml xrechnung.xml].freeze

  # UNTDID 1001 codes for credit notes in EN 16931.
  CREDIT_NOTE_TYPE_CODES = %w[81 83 261 262 296 308 381 396 420 458 532].freeze

  # Element names along the path to each value. ZUGFeRD 1 used other names for
  # the same structure.
  CII_LAYOUTS = {
    "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100" => {
      document: "ExchangedDocument",
      transaction: "SupplyChainTradeTransaction",
      agreement: "ApplicableHeaderTradeAgreement",
      settlement: "ApplicableHeaderTradeSettlement",
      summation: "SpecifiedTradeSettlementHeaderMonetarySummation"
    },
    "urn:ferd:CrossIndustryDocument:invoice:1p0" => {
      document: "HeaderExchangedDocument",
      transaction: "SpecifiedSupplyChainTradeTransaction",
      agreement: "ApplicableSupplyChainTradeAgreement",
      settlement: "ApplicableSupplyChainTradeSettlement",
      summation: "SpecifiedTradeSettlementMonetarySummation"
    }
  }.freeze
  UBL_NAMESPACES = {
    "Invoice" => "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
    "CreditNote" => "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2"
  }.freeze

  DECIMAL = /\A-?\d{1,15}(?:\.\d{1,6})?\z/

  class << self
    # Returns { "field" => { value:, confidence: } } for each field it could
    # read, or {} when the XML is not an invoice it knows.
    def parse(xml)
      new(xml).parse
    end

    # Tries the embedded XML files, the standard's names first, and stops at
    # the first invoice. Each file is inflated only when its turn comes.
    def from_pdf(content)
      xml_files = Pdf::EmbeddedFiles.list(content).select { |file| file.name.downcase.end_with?(".xml") }
      known, others = xml_files.partition { |file| PDF_ATTACHMENT_NAMES.include?(file.name.downcase) }

      (known + others).first(MAX_PDF_FILES_TRIED).each do |file|
        xml = file.read(max_size: MAX_SIZE)
        next if xml.nil?

        fields = parse(xml)
        return fields if fields.any?
      end
      {}
    end
  end

  def initialize(xml)
    @xml = xml.to_s
  end

  def parse
    root = document&.root
    return {} if root.nil?

    values =
      if (layout = CII_LAYOUTS[root.namespace&.href]) && root.name.in?(%w[CrossIndustryInvoice CrossIndustryDocument])
        cii_values(root, layout)
      elsif UBL_NAMESPACES[root.name] == root.namespace&.href
        ubl_values(root)
      end
    return {} if values.nil?

    values.compact.transform_values { |value| { value: value, confidence: CONFIDENCE } }
  end

  private
    # E-invoices never declare a DTD. Refusing one rules out entity expansion
    # and external fetches: the text check catches it before libxml2 sees the
    # document, the subset check after parsing catches other encodings (UTF-16).
    # Entities are never substituted (no NOENT) and the network is off.
    def document
      return if @xml.bytesize > MAX_SIZE || @xml.match?(/<!DOCTYPE/i)

      document = Nokogiri::XML(@xml) { |config| config.strict.nonet }
      document unless document.internal_subset || document.external_subset
    rescue Nokogiri::XML::SyntaxError, ArgumentError, EncodingError
      nil
    end

    def cii_values(root, layout)
      header = child(root, layout[:document])
      trade = child(root, layout[:transaction])
      settlement = child(trade, layout[:settlement])
      summation = child(settlement, layout[:summation])
      currency = currency_code(text(child(settlement, "InvoiceCurrencyCode")))
      credit_note = text(child(header, "TypeCode")).in?(CREDIT_NOTE_TYPE_CODES)

      {
        "merchant_name" => text(child(trade, layout[:agreement], "SellerTradeParty", "Name")),
        "date" => cii_date(child(header, "IssueDateTime", "DateTimeString")),
        "amount" => (positive_amount(summation, "GrandTotalAmount", currency) unless credit_note),
        "currency" => currency,
        "invoice_number" => text(child(header, "ID"))&.first(100),
        "due_date" => cii_date(child(settlement, "SpecifiedTradePaymentTerms", "DueDateDateTime", "DateTimeString")),
        "tax_amount" => (amount(summation, "TaxTotalAmount", currency) unless credit_note)
      }
    end

    def ubl_values(root)
      party = child(root, "AccountingSupplierParty", "Party")
      currency = currency_code(text(child(root, "DocumentCurrencyCode")))
      credit_note = root.name == "CreditNote" || text(child(root, "InvoiceTypeCode")).in?(CREDIT_NOTE_TYPE_CODES)
      tax_amounts = children(root, "TaxTotal").filter_map { |total| amount(total, "TaxAmount", currency) }

      {
        "merchant_name" => text(child(party, "PartyName", "Name")) || text(child(party, "PartyLegalEntity", "RegistrationName")),
        "date" => iso_date(child(root, "IssueDate")),
        "amount" => (positive_amount(child(root, "LegalMonetaryTotal"), "TaxInclusiveAmount", currency) unless credit_note),
        "currency" => currency,
        "invoice_number" => text(child(root, "ID"))&.first(100),
        "due_date" => iso_date(child(root, "DueDate")) || iso_date(child(root, "PaymentMeans", "PaymentDueDate")),
        "tax_amount" => (tax_amounts.first unless credit_note)
      }
    end

    # Walks element children by local name, so namespace prefixes do not matter.
    def child(node, *names)
      names.reduce(node) { |current, name| current && children(current, name).first }
    end

    def children(node, name)
      return [] if node.nil?

      node.element_children.select { |element| element.name == name }
    end

    def text(node)
      node&.text&.squish.presence
    end

    def currency_code(code)
      return if code.blank?

      Money::Currency.new(code).iso_code
    rescue Money::Currency::UnknownCurrencyError
      nil
    end

    # An amount element may repeat in another currency (CII states the tax in
    # both the invoice and the tax currency); the one in the invoice currency,
    # or one without a currency, counts.
    def amount(parent, name, currency)
      elements = children(parent, name)
      element = elements.find { |candidate| candidate["currencyID"].present? && candidate["currencyID"].strip.upcase == currency } ||
        elements.find { |candidate| candidate["currencyID"].blank? }
      value = text(element)
      BigDecimal(value) if value&.match?(DECIMAL)
    end

    def positive_amount(parent, name, currency)
      value = amount(parent, name, currency)
      value if value&.positive?
    end

    # CII dates are "102" (YYYYMMDD) unless they say otherwise; the other
    # formats name a month or a week, not a day.
    def cii_date(node)
      return if node.nil?
      return if node["format"].present? && node["format"] != "102"

      parse_date(text(node)&.match(/\A(\d{8})\z/)&.[](1), "%Y%m%d")
    end

    # xs:date may carry a time zone ("2026-11-05+01:00"); the day is enough.
    def iso_date(node)
      parse_date(text(node)&.match(/\A(\d{4}-\d{2}-\d{2})(?:Z|[+-]\d{2}:\d{2})?\z/)&.[](1), "%Y-%m-%d")
    end

    def parse_date(value, format)
      return if value.blank?

      Date.strptime(value, format)
    rescue Date::Error
      nil
    end
end
