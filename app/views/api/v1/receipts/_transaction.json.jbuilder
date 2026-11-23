# frozen_string_literal: true

entry = transaction.entry
json.id transaction.id
json.entry_id entry.id
json.name entry.name
json.date entry.date.iso8601
json.amount_decimal entry.amount.to_s("F")
json.currency entry.currency
json.account do
  json.id entry.account.id
  json.name entry.account.name
end
