# frozen_string_literal: true

# QR codes on photos and PDFs: till receipts (DSFinV-K, RKSV) and transfer
# codes (GiroCode/EPC, Swiss QR). Their contents are not added to the raw text:
# they hold IBANs and signatures, and the fields read from them are shown anyway.
#
# A code that identifies the till or payee is stored as a digest, so a later
# receipt from the same till gets the merchant the user confirmed for an earlier
# one.
class Receipt::Extraction::Stages::Qr < Receipt::Extraction::Stage
  # The merchant of an earlier receipt from the same till or payee was confirmed
  # by the user, so it beats the name printed in a transfer code.
  LEARNED_MERCHANT_CONFIDENCE = 0.95

  def self.position
    20
  end

  def self.source
    "qr"
  end

  def self.default_attributes
    { merchant_identifiers: [] }
  end

  def read
    payloads = Receipt::QrReader.read(extraction.content, content_type: receipt.content_type)
    return nil if payloads.empty?

    result = Receipt::QrParser.parse(payloads, timezone: receipt.family.timezone)
    fields = result.fields.dup
    if (merchant = learned_merchant(result.identifiers))
      fields["merchant_name"] = { value: merchant.name, confidence: LEARNED_MERCHANT_CONFIDENCE }
    end

    Reading.new(fields: fields, attributes: { merchant_identifiers: result.identifiers })
  rescue Receipt::ExternalCommand::Error => e
    # Without the QR stage the receipt is still read from its text.
    DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt##{receipt.id}: QR stage skipped: #{e.class}",
                          source: "receipt_extraction", family: receipt.family, user_id: receipt.uploaded_by_id)
    nil
  end

  private
    # The merchant of the most recently linked receipt from the same till or
    # payee, read from its transaction now, so a merchant set later by hand or
    # by a rule counts too. Only links the user made or confirmed count, and
    # only transactions on accounts the uploader can see are consulted.
    def learned_merchant(identifiers)
      digests = Array(identifiers).filter_map { |identifier| identifier["digest"].presence }
      return nil if digests.empty? || receipt.uploaded_by.nil?

      earlier = receipt.family.receipts.linked
        .where.not(id: receipt.id)
        .where("receipts.merchant_identifiers @> ANY (ARRAY[?]::jsonb[])", digests.map { |digest| [ { digest: digest } ].to_json })
        .joins(linked_transaction: :entry)
        .where(entries: { account_id: receipt.family.accounts.accessible_by(receipt.uploaded_by).select(:id) })
        .where.not(transactions: { merchant_id: nil })
        .order(linked_at: :desc)
        .first

      earlier&.linked_transaction&.merchant
    end
end
