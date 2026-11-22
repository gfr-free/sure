# frozen_string_literal: true

# Remembers which merchant a receipt identifier (a till's id, a payee's IBAN
# ending and name) belonged to the last time a receipt with it was linked, so the
# next receipt from the same till or payee gets that merchant.
class ReceiptMerchantHint < ApplicationRecord
  KINDS = %w[tse rksv payee].freeze

  belongs_to :family
  belongs_to :merchant

  validates :kind, inclusion: { in: KINDS }
  validates :value, presence: true, length: { maximum: 200 }

  class << self
    # The merchant last confirmed for any of the identifiers, if the family can
    # still see it.
    def merchant_for(family, identifiers)
      identifiers = Array(identifiers).select { |identifier| KINDS.include?(identifier["kind"]) && identifier["value"].present? }
      return nil if identifiers.empty?

      conditions = identifiers.map { |identifier| sanitize_sql_array([ "(kind = ? AND value = ?)", identifier["kind"], identifier["value"] ]) }
      hint = family.receipt_merchant_hints.where(conditions.join(" OR ")).includes(:merchant).order(updated_at: :desc).first
      merchant = hint&.merchant
      merchant if merchant && family.available_merchants.exists?(merchant.id)
    end

    def learn!(family, identifiers, merchant)
      return if merchant.nil?

      Array(identifiers).each do |identifier|
        next unless KINDS.include?(identifier["kind"]) && identifier["value"].present?

        upsert(
          { family_id: family.id, kind: identifier["kind"], value: identifier["value"].to_s.first(200), merchant_id: merchant.id },
          unique_by: %i[family_id kind value],
          update_only: %i[merchant_id],
          record_timestamps: true
        )
      end
    end
  end
end
