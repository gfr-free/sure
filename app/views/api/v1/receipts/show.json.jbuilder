# frozen_string_literal: true

json.data do
  json.partial! "api/v1/receipts/receipt", receipt: @receipt
end

json.meta do
  json.duplicate !!@duplicate
end
