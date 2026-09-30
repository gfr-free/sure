module Provider::SecurityConcept
  extend ActiveSupport::Concern

  # NOTE: This `Security` is a lightweight Data value object used for search results.
  # Inside provider classes that `include SecurityConcept`, unqualified `Security`
  # resolves to this Data class — NOT to `::Security` (the ActiveRecord model).
  Security = Data.define(:symbol, :name, :logo_url, :exchange_operating_mic, :country_code, :currency) do
    def initialize(symbol:, name:, logo_url:, exchange_operating_mic:, country_code:, currency: nil)
      super
    end
  end
  SecurityInfo = Data.define(:symbol, :name, :links, :logo_url, :description, :kind, :exchange_operating_mic)
  Price = Data.define(:symbol, :date, :price, :currency, :exchange_operating_mic)
  # `ratio_from` old shares became `ratio_to` new shares on `date`.
  Split = Data.define(:symbol, :date, :ratio_from, :ratio_to)

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    raise NotImplementedError, "Subclasses must implement #search_securities"
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_info"
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_price"
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    raise NotImplementedError, "Subclasses must implement #fetch_security_prices"
  end

  # Whether historical prices from this provider are already adjusted for
  # stock splits (quoted on today's share basis). Holdings are calculated on
  # that basis, so prices from providers that return raw historical quotes are
  # divided by the split factor before use.
  def split_adjusted_prices?
    false
  end

  # Maximum number of calendar days of historical data the provider can return.
  # Callers should clamp start_date to avoid requesting data beyond this window.
  # Override in subclasses with provider-specific limits.
  def max_history_days
    nil # nil means no known limit
  end
end
