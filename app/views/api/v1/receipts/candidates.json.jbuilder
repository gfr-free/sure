# frozen_string_literal: true

json.data do
  json.array! @candidates, partial: "api/v1/receipts/transaction", as: :transaction
end
