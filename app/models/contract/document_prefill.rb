# Seeds a new contract from the terms the PDF processor read out of an
# uploaded contract document. Every value is re-validated here: it came from
# an LLM. Numbers are never part of it; the user types them.
class Contract::DocumentPrefill
  DATE_KEYS = %w[started_on renewal_anchor_on ends_on].freeze
  INTEGER_KEYS = %w[minimum_term_months notice_period_value renewal_period_months].freeze

  def initialize(pdf_import)
    @terms = pdf_import.extracted_data.to_h["contract"].to_h
    @pdf_import = pdf_import
  end

  def any?
    terms.values.any?(&:present?)
  end

  def apply_to(contract)
    contract.name = terms["name"].to_s.strip.first(255).presence || pdf_import.pdf_filename.to_s.sub(/\.pdf\z/i, "").presence
    contract.provider_name = terms["provider"].to_s.strip.first(255).presence
    contract.kind = terms["kind"] if terms["kind"].in?(Contract.kinds.keys)
    contract.notice_period_unit = terms["notice_period_unit"] if terms["notice_period_unit"].in?(Contract.notice_period_units.keys)
    contract.notice_anchor = terms["notice_anchor"] if terms["notice_anchor"].in?(Contract.notice_anchors.keys)

    INTEGER_KEYS.each do |key|
      value = Integer(terms[key].to_s, exception: false)
      contract.public_send("#{key}=", value) if value && value >= 0
    end
    contract.renewal_period_months = nil if contract.renewal_period_months.to_i.zero?

    DATE_KEYS.each do |key|
      date = Date.iso8601(terms[key].to_s) rescue nil
      contract.public_send("#{key}=", date) if date
    end

    contract
  end

  # "€ 65.00 per year" style hint for the form; the premium itself becomes a
  # bill the user links or adds.
  def premium
    amount = BigDecimal(terms["premium_amount"].to_s) rescue nil
    return if amount.nil? || amount <= 0

    { amount: amount, frequency: terms["premium_frequency"].presence }
  end

  private
    attr_reader :terms, :pdf_import
end
