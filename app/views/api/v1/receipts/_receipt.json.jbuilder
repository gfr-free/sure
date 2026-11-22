# frozen_string_literal: true

json.id receipt.id
json.status receipt.status
json.source receipt.source
json.filename receipt.filename
json.content_type receipt.content_type
json.byte_size receipt.byte_size
json.content_sha256 receipt.content_sha256
json.extraction_status receipt.extraction_status
json.extraction_error receipt.extraction_error
json.merchant_name receipt.merchant_name
json.date receipt.date&.iso8601
json.amount receipt.amount&.to_s("F")
json.currency receipt.currency

json.field_sources do
  Receipt::FIELDS.each do |field|
    source = receipt.field_source(field)
    if source
      json.set! field do
        json.source source
        json.confidence receipt.field_confidence(field)&.to_f
      end
    else
      json.set! field, nil
    end
  end
end

transaction = receipt.linked_transaction
if transaction && accessible_account_ids.include?(transaction.entry.account_id)
  json.transaction do
    json.partial! "api/v1/receipts/transaction", transaction: transaction
  end
else
  json.transaction nil
end
json.created_transaction receipt.created_transaction
json.linked_at receipt.linked_at&.iso8601
json.dismissed_at receipt.dismissed_at&.iso8601
json.created_at receipt.created_at.iso8601
json.updated_at receipt.updated_at.iso8601
