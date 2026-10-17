# frozen_string_literal: true

# Per-account forecast after the expected payments (Account::Forecast,
# decision E13): "will my bills account last until payday?".
class Assistant::Function::GetAccountForecast < Assistant::Function
  class << self
    def name
      "get_account_forecast"
    end

    def description
      <<~INSTRUCTIONS
        Forecast one account's balance after the payments expected on it: open bills paid
        from it, declared income paid into it, and recurring transfers out of it or into it.
        Answers questions like "will my bills account cover everything until payday?" or
        "how much is left on my current account after this month's bills?".

        - The window runs up to the day before the next declared payday on that account,
          otherwise 30 days. Pass `until` to choose another end date.
        - No statistical day-to-day spending is included; only known expected payments.
        - Only accounts whose money is available immediately (current accounts, cash,
          instant-access savings) can be forecast. Get account ids from get_accounts.
        - `shortfall` is true when the balance falls below zero after today;
          `shortfall_amount` is what must arrive by `top_up_by` to stay at zero.
        - Amounts are in the account's own currency.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id],
      properties: {
        account_id: { type: "string", description: "UUID of the account, from get_accounts." },
        until: { type: "string", description: "Optional last day of the forecast (YYYY-MM-DD), at most 366 days ahead." }
      }
    )
  end

  def call(params = {})
    account_id = params["account_id"].to_s
    return error("invalid_account_id", "account_id must be a UUID from get_accounts.") unless valid_uuid?(account_id)

    account = family.accounts.accessible_by(user).find_by(id: account_id)
    return error("account_not_found", "No account found with that ID that this user can see.") unless account

    unless Account::Forecast.forecastable?(account)
      return error("not_forecastable", "#{account.name} is not an account whose money is available immediately, so it has no forecast.")
    end

    until_date = parse_until(params["until"])
    return error("invalid_until", "until must be a date (YYYY-MM-DD).") if until_date == :invalid

    today = Account.liquidity_today_for(account.family)
    if until_date && (until_date < today || until_date > today + Account::Forecast::MAX_HORIZON_DAYS)
      return error("invalid_until", "until must be between today and #{Account::Forecast::MAX_HORIZON_DAYS} days ahead.")
    end

    forecast = Account::Forecast.for_account(account, user: user, until_date: until_date)

    {
      account: { id: account.id, name: account.name, currency: account.currency },
      starts_on: forecast.starts_on.iso8601,
      ends_on: forecast.ends_on.iso8601,
      horizon: forecast.horizon.to_s,
      next_payday: forecast.payday&.iso8601,
      starting_balance: forecast.starting_balance.format,
      ending_balance: forecast.ending_balance.format,
      low_balance: forecast.low_balance.format,
      low_on: forecast.low_on.iso8601,
      shortfall: forecast.shortfall?,
      shortfall_amount: forecast.shortfall? ? forecast.shortfall_amount.format : nil,
      top_up_by: forecast.top_up_by&.iso8601,
      unconvertible_count: forecast.unconvertible_count,
      expected_payments: forecast.events.map do |event|
        {
          date: event.date.iso8601,
          name: event.name,
          kind: event.kind.to_s,
          amount: event.amount.format,
          balance_after: event.balance_after.format
        }
      end
    }.compact
  end

  private
    def parse_until(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      :invalid
    end

    def error(code, message)
      { error: code, message: message }
    end
end
