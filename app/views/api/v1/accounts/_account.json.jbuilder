# frozen_string_literal: true

balance_money = account.balance_money
cash_balance_money = account.cash_balance_money

json.id account.id
json.name account.name
json.balance balance_money.format
json.balance_cents((balance_money.amount * balance_money.currency.minor_unit_conversion).round(0).to_i)
json.cash_balance cash_balance_money.format
json.cash_balance_cents((cash_balance_money.amount * cash_balance_money.currency.minor_unit_conversion).round(0).to_i)
json.currency account.currency
json.classification account.classification
json.account_type account.accountable_type&.underscore
json.subtype account.subtype
json.liquidity account.liquidity
json.available_on account.available_on&.iso8601
json.notice_period_days account.notice_period_days
json.available_now account.available_on?
# Interest terms (Account::Interest). The amounts need the daily balances, so
# they are only in the single-account response.
if account.interest_terms?
  interest_today = account.liquidity_today
  projection = account.interest_projection(as_of: interest_today)
  interest_money = ->(value) { value && { amount: value.amount.to_s, formatted: value.format } }

  json.interest do
    json.rate projection.credit_rate&.to_s
    json.debit_rate projection.debit_rate&.to_s
    json.payout_frequency projection.frequency
    json.day_count projection.day_count
    json.next_payout_on projection.next_payout_date&.iso8601
    json.rate_changes account.upcoming_interest_rates(interest_today) do |entry|
      json.effective_from entry.effective_from.iso8601
      json.rate entry.rate.to_s
      json.applies_to entry.applies_to
    end

    if local_assigns[:detailed]
      json.accrued interest_money.call(projection.accrued)
      json.next_payout_amount interest_money.call(projection.next_payout&.amount)
      json.value_at_maturity interest_money.call(projection.value_at_maturity)
    end
  end
else
  json.interest nil
end
# Tax settings (Account::Taxation). Only the account's own values: a null
# withheld_at_source follows the owner's tax profile.
if account.tax_capable?
  json.tax do
    json.treatment account.tax_treatment&.to_s
    json.withheld_at_source account.tax_withheld_at_source
    json.allowance_allocation account.tax_allowance_allocation&.to_s
    json.january_tax_debit account.january_tax_debit&.to_s
    json.joint_user_id account.tax_joint_user_id
    json.owner_share account.tax_joint? ? account.effective_tax_owner_share.to_s : nil
    json.loss_pots account.loss_pots.sort_by { |pot| LossPot::KINDS.index(pot.kind) } do |pot|
      latest = pot.latest_snapshot
      json.kind pot.kind
      json.carry_forward pot.carry_forward
      json.amount latest&.amount&.to_s
      json.as_of latest&.date
    end
  end
else
  json.tax nil
end
json.status account.status
json.institution_name account.institution_name
json.institution_domain account.institution_domain
json.created_at account.created_at.iso8601
json.updated_at account.updated_at.iso8601
