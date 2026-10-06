# frozen_string_literal: true

money = ->(value) { { amount: value.amount.to_s, formatted: value.format } }

json.account_id @forecast.account.id
json.currency @forecast.currency
json.starts_on @forecast.starts_on.iso8601
json.ends_on @forecast.ends_on.iso8601
json.horizon @forecast.horizon.to_s
json.next_payday @forecast.payday&.iso8601
json.starting_balance money.call(@forecast.starting_balance)
json.ending_balance money.call(@forecast.ending_balance)
json.low_balance money.call(@forecast.low_balance)
json.low_on @forecast.low_on.iso8601
json.shortfall @forecast.shortfall?
json.shortfall_amount money.call(@forecast.shortfall_amount)
json.top_up_by @forecast.top_up_by&.iso8601
json.unconvertible_count @forecast.unconvertible_count

payments, interest = @forecast.events.partition(&:occurrence)

json.events payments do |event|
  json.date event.date.iso8601
  json.name event.name
  json.kind event.kind.to_s
  json.amount money.call(event.amount)
  json.balance_after money.call(event.balance_after)
  json.recurring_transaction_id event.series.id
  json.occurrence_id event.occurrence.id
end

if @include_interest
  json.interest_payments interest do |event|
    json.date event.date.iso8601
    json.amount money.call(event.amount)
    json.balance_after money.call(event.balance_after)
  end
end
