# frozen_string_literal: true

require "digest/sha2"

# Reads header data from the QR codes printed on receipts and invoices:
#
# - German till receipts (DSFinV-K, "V0;…;Kassenbeleg-V1;…"): total per tax rate
#   and the time, signed by the till's security module.
# - Austrian till receipts (RKSV, "_R1-AT…"): total per tax rate and the time.
# - GiroCode / EPC transfer codes ("BCD"): payee and amount.
# - Swiss QR-bills ("SPC"): payee, amount and currency.
#
# Till codes carry no shop name. Each format that identifies its sender returns an
# identifier (the till's signing key or certificate plus its id, or the payee's
# IBAN ending and name) so a merchant confirmed once can be recognised next time.
# Identifiers are stored as digests only; the IBAN part uses its last four
# characters.
class Receipt::QrParser
  Result = Data.define(:fields, :identifiers)

  SIGNED_CONFIDENCE = 0.95
  TRANSFER_CONFIDENCE = 0.9
  MAX_AMOUNT = BigDecimal("999999999.99")
  TSE_RECEIPT_TYPES = %w[Beleg AVRechnung].freeze

  def self.parse(payloads, timezone: nil)
    new(payloads, timezone:).parse
  end

  def initialize(payloads, timezone: nil)
    @payloads = Array(payloads)
    @timezone = ActiveSupport::TimeZone[timezone.to_s] || Time.zone
  end

  # Till receipts come first: their amount and time are signed. A transfer code's
  # amount can be a partial payment, so it only fills what is still missing.
  def parse
    readings = @payloads.filter_map { |payload| read(payload) }.sort_by { |reading| reading[:rank] }

    fields = {}
    readings.each do |reading|
      reading[:fields].each { |field, value| fields[field] ||= value }
    end

    Result.new(fields: fields, identifiers: readings.flat_map { |reading| reading[:identifiers] }.uniq)
  end

  private
    def read(payload)
      text = payload.to_s.strip
      if text.start_with?("V0;")
        german_till(text)
      elsif text.start_with?("_R1-AT")
        austrian_till(text)
      elsif text.start_with?("BCD")
        epc(text)
      elsif text.start_with?("SPC")
        swiss_bill(text)
      end
    end

    # V0;<till serial>;<process type>;<process data>;<transaction>;<counter>;<start>;<end>;<algorithm>;<time format>;<signature>;<public key>
    # Process data for Kassenbeleg-V1: <receipt type>^<gross per tax rate, "_"-separated>^<payments>
    def german_till(text)
      parts = text.split(";")
      return nil unless parts.size >= 12 && parts[2] == "Kassenbeleg-V1"

      receipt_type, gross = parts[3].to_s.split("^")
      return nil unless TSE_RECEIPT_TYPES.include?(receipt_type)

      fields = {}
      total = sum_amounts(gross.to_s.split("_"), separator: ".")
      fields["amount"] = signed(total) if total
      date = plausible(time_to_date(parts[7].presence || parts[6]))
      fields["date"] = signed(date) if date
      fields["currency"] = signed("EUR") if fields.key?("amount")

      identifiers = []
      if parts[1].present? && parts[11].present?
        identifiers << identifier("tse", "#{parts[11]}:#{parts[1]}")
      end

      { rank: 0, fields: fields, identifiers: identifiers }
    end

    # _R1-AT<n>_<till id>_<receipt no>_<YYYY-MM-DDThh:mm:ss>_<normal>_<reduced 1>_<reduced 2>_<zero>_<special>_<counter>_<certificate serial>_<signatures>
    def austrian_till(text)
      parts = text.split("_")
      return nil unless parts.size >= 12

      fields = {}
      total = sum_amounts(parts[5..9], separator: ",")
      fields["amount"] = signed(total) if total
      date = plausible(local_date(parts[4]))
      fields["date"] = signed(date) if date
      fields["currency"] = signed("EUR") if fields.key?("amount")

      identifiers = []
      identifiers << identifier("rksv", "#{parts[11]}:#{parts[2]}") if parts[2].present? && parts[11].present?

      { rank: 1, fields: fields, identifiers: identifiers }
    end

    # BCD / version / charset / SCT / BIC / name / IBAN / EUR<amount> / purpose / reference / text
    def epc(text)
      lines = text.split(/\r?\n/).map(&:strip)
      return nil unless lines[3] == "SCT" && lines[5].present? && lines[6].present?

      fields = { "merchant_name" => transfer(lines[5]) }
      if (match = lines[7].to_s.match(/\AEUR(\d{1,9}(?:\.\d{1,2})?)\z/))
        amount = BigDecimal(match[1])
        if amount.positive?
          fields["amount"] = transfer(amount)
          fields["currency"] = transfer("EUR")
        end
      end

      { rank: 2, fields: fields, identifiers: [ payee_identifier(lines[6], lines[5]) ].compact }
    end

    # SPC / version / coding / IBAN / creditor (7 lines) / ultimate creditor (7 lines) / amount / currency / …
    def swiss_bill(text)
      lines = text.split(/\r?\n/).map(&:strip)
      return nil unless lines.size >= 20 && lines[3].present? && lines[5].present?

      fields = { "merchant_name" => transfer(lines[5]) }
      amount = parse_amount(lines[18], separator: ".")
      if amount&.positive? && %w[CHF EUR].include?(lines[19])
        fields["amount"] = transfer(amount)
        fields["currency"] = transfer(lines[19])
      end

      { rank: 3, fields: fields, identifiers: [ payee_identifier(lines[3], lines[5]) ].compact }
    end

    def sum_amounts(values, separator:)
      amounts = values.map { |value| parse_amount(value, separator:) }
      return nil if amounts.empty? || amounts.any?(&:nil?)

      total = amounts.sum
      total.positive? && total <= MAX_AMOUNT ? total : nil
    end

    def parse_amount(value, separator:)
      text = value.to_s.strip
      return nil unless text.match?(/\A-?\d{1,12}(?:#{Regexp.escape(separator)}\d{1,4})?\z/)

      BigDecimal(text.tr(separator, "."))
    end

    def plausible(date)
      return nil if date.nil?

      today = Time.current.in_time_zone(@timezone).to_date
      date.between?(today - Receipt::TextParser::MAX_AGE, today + 1) ? date : nil
    end

    def time_to_date(value)
      Time.iso8601(value.to_s).in_time_zone(@timezone).to_date
    rescue ArgumentError
      nil
    end

    # Austrian receipts print local time without a zone.
    def local_date(value)
      return nil unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}T/)

      Date.iso8601(value.to_s.first(10))
    rescue Date::Error
      nil
    end

    def payee_identifier(iban, name)
      compact = iban.to_s.delete(" ").upcase
      normalized_name = name.to_s.squish.downcase
      return nil if compact.length < 6 || normalized_name.blank?

      identifier("payee", "#{compact.first(2)}#{compact.last(4)}:#{normalized_name}")
    end

    def identifier(kind, value)
      { "kind" => kind, "digest" => Digest::SHA256.hexdigest("#{kind}:#{value}") }
    end

    def signed(value)
      { value: value, confidence: SIGNED_CONFIDENCE }
    end

    def transfer(value)
      { value: value, confidence: TRANSFER_CONFIDENCE }
    end
end
