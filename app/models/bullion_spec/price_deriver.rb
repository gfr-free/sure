# Derives daily prices for bullion securities. Coins and bars have no market
# feed of their own; their price is the fine metal content times the price of
# a reference security per metal. The user only picks the provider
# (Setting.bullion_reference_provider); the reference symbol for each metal
# follows from it. The reference is an ordinary security priced by that
# provider. Derived prices keep the reference's currency.
#
# A coin that is legal tender is never priced below its face value, converted
# into the reference's currency at that day's exchange rate. Without a rate
# the metal value stands and the gap is logged, never a 1:1 guess.
class BullionSpec::PriceDeriver
  DEFAULT_LOOKBACK_DAYS = MarketDataImporter::SNAPSHOT_DAYS
  DEFAULT_REFERENCE_PROVIDER = "yahoo_finance".freeze

  # [ticker, exchange MIC] per metal for each securities provider whose metal
  # symbols are verified. Add a provider here only after checking that it
  # returns daily prices for these symbols.
  REFERENCE_SYMBOLS = {
    "yahoo_finance" => {
      "XAU" => [ "GC=F", "CMX" ],
      "XAG" => [ "SI=F", "CMX" ],
      "XPT" => [ "PL=F", "NYM" ],
      "XPD" => [ "PA=F", "NYM" ]
    },
    # Twelve Data's free plan quotes gold only; the other metals need a paid plan.
    "twelve_data" => {
      "XAU" => [ "XAU/USD", nil ],
      "XAG" => [ "XAG/USD", nil ],
      "XPT" => [ "XPT/USD", nil ],
      "XPD" => [ "XPD/USD", nil ]
    }
  }.freeze

  class << self
    def reference_provider
      provider = Setting.bullion_reference_provider.to_s
      REFERENCE_SYMBOLS.key?(provider) ? provider : DEFAULT_REFERENCE_PROVIDER
    end

    # Providers the settings offer: those with known symbols that the app has.
    def available_reference_providers
      REFERENCE_SYMBOLS.keys & Security.valid_price_providers
    end

    def reference_symbol(metal)
      REFERENCE_SYMBOLS.dig(reference_provider, metal.to_s)
    end

    def reference_security(metal)
      ticker, mic = reference_symbol(metal)
      return nil if ticker.blank?

      security = begin
        Security.find_or_create_by!(ticker: ticker, exchange_operating_mic: mic) do |new_security|
          new_security.price_provider = reference_provider
        end
      rescue ActiveRecord::RecordNotUnique
        Security.find_by(ticker: ticker, exchange_operating_mic: mic)
      end

      adopt_configured_provider(security, reference_provider)
    end

    # True when the chosen provider is not enabled, so no reference (and no
    # coin or bar) gets new prices.
    def reference_provider_disabled?
      Setting.enabled_securities_providers.exclude?(reference_provider)
    end

    private
      # The reference may already exist with another provider (held as a
      # stock, say). The setting decides, so a changed provider takes effect.
      def adopt_configured_provider(security, provider)
        return security if security.nil? || security.price_provider == provider

        attrs = { price_provider: provider }
        # Taken offline because the old provider was disabled: back online once
        # the new one is enabled, matching Settings::HostingsController.
        if security.offline_reason == "provider_disabled" && Setting.enabled_securities_providers.include?(provider)
          attrs.merge!(offline: false, offline_reason: nil, failed_fetch_count: 0, failed_fetch_at: nil)
        end
        security.update!(attrs)
        security
      end
  end

  # security_ids limits derivation to those bullion securities (an account
  # sync); nil derives every catalogue and custom piece (the daily import).
  def initialize(end_date: Date.current, start_date: nil, security_ids: nil)
    @end_date = end_date
    @start_date = start_date
    @security_ids = security_ids
  end

  def derive_all
    specs = BullionSpec.all
    specs = specs.where(security_id: security_ids) unless security_ids.nil?

    specs.group_by(&:metal).each do |metal, metal_specs|
      derive_metal(metal, metal_specs)
    end
  end

  private
    attr_reader :end_date, :security_ids

    def derive_metal(metal, specs)
      reference = self.class.reference_security(metal)
      return if reference.nil?

      start_date = start_date_for(specs)
      if reference.provider_status == :provider_unavailable
        capture_unavailable_provider(metal, reference)
      elsif !reference.offline?
        reference.import_provider_prices(start_date: start_date, end_date: end_date)
      end

      reference_prices = Security::Price.where(security_id: reference.id, date: start_date..end_date).to_a
      rates = FaceValueRates.new(start_date: start_date, end_date: end_date)
      lowest_reference = reference_prices.min_by(&:price)
      rows = specs.flat_map do |spec|
        face_value = spec.nominal_value
        if face_value && lowest_reference &&
           !rates.floor_possible?(face_value, to: lowest_reference.currency, lowest_metal_value: lowest_reference.price * spec.fine_troy_ounces)
          face_value = nil
        end

        reference_prices.map do |price|
          metal_value = price.price * spec.fine_troy_ounces
          floor = face_value && rates.convert(face_value, to: price.currency, date: price.date)
          {
            security_id: spec.security_id,
            date: price.date,
            currency: price.currency,
            price: [ metal_value, floor || 0 ].max.round(4),
            provisional: price.provisional
          }
        end
      end
      capture_missing_rates(metal, rates.missing) if rates.missing.any?
      return if rows.empty?

      Security::Price.upsert_all(rows, unique_by: %i[security_id date currency])

      # A reference currency change must not leave a second, stale row per date.
      Security::Price.where(security_id: specs.map(&:security_id)).where.not(currency: rows.map { |row| row[:currency] }.uniq).delete_all
    rescue StandardError => e
      Rails.logger.error("Bullion price derivation failed for #{metal}: #{e.class}: #{e.message}")
      DebugLogEntry.capture(
        category: "security_price_fetch",
        level: "error",
        message: "Could not derive bullion prices",
        source: self.class.name,
        metadata: { metal: metal, reference_security_id: reference&.id, error: "#{e.class}: #{e.message}" }
      )
    end

    # Without this the sync succeeds silently and coins keep their last price.
    def capture_unavailable_provider(metal, reference)
      DebugLogEntry.capture(
        category: "security_price_fetch",
        level: "warn",
        message: "Bullion reference price provider is not enabled",
        source: self.class.name,
        provider: reference.price_provider,
        metadata: { metal: metal, reference_security_id: reference.id, ticker: reference.ticker, price_provider: reference.price_provider }
      )
    end

    def capture_missing_rates(metal, missing)
      DebugLogEntry.capture(
        category: "security_price_fetch",
        level: "warn",
        message: "No exchange rate for a bullion face value; the metal value was used",
        source: self.class.name,
        metadata: { metal: metal, missing: missing.map { |(from, to), dates| { from: from, to: to, first_date: dates.min, last_date: dates.max } } }
      )
    end

    # From the first trade of any piece of this metal, so history is complete.
    def start_date_for(specs)
      @start_date ||
        Trade.with_entry.where(security_id: specs.map(&:security_id)).minimum(:date) ||
        DEFAULT_LOOKBACK_DAYS.days.ago.to_date
    end

    # Daily exchange rates for converting face values. A day without its own
    # rate takes the most recent one from up to five days before, as
    # ExchangeRate.find_or_fetch_rate does. Rate history is only loaded for a
    # coin whose face value could matter, so a Maple Leaf (50 CAD against
    # thousands in gold) costs one cached rate, not a year of CAD rates.
    class FaceValueRates
      LOOKBACK_DAYS = 5
      # Exchange rates move, but not by half within the window.
      SAFETY_FACTOR = 2

      attr_reader :missing

      def initialize(start_date:, end_date:)
        @start_date = start_date
        @end_date = end_date
        @rates = {}
        @missing = Hash.new { |hash, key| hash[key] = [] }
      end

      # False when the face value stays far below the lowest metal value at
      # the latest rate, so no day's floor can apply.
      def floor_possible?(money, to:, lowest_metal_value:)
        from = money.currency.iso_code
        return true if from == to

        rate = latest_rate(from, to)
        rate.nil? || money.amount * rate * SAFETY_FACTOR >= lowest_metal_value
      end

      # The amount in `to` on `date`, or nil when no rate is known.
      def convert(money, to:, date:)
        from = money.currency.iso_code
        return money.amount if from == to

        rate = rate_on(from, to, date)
        return money.amount * rate if rate

        missing[[ from, to ]] << date
        nil
      end

      private
        attr_reader :start_date, :end_date

        def latest_rate(from, to)
          stored = stored(from, to)
          return stored.last.last if stored.any?

          rate = ExchangeRate.find_or_fetch_rate(from: from, to: to, date: end_date)&.rate
          rate if rate && ExchangeRate.valid_rate?(rate)
        rescue StandardError => e
          Rails.logger.warn("Bullion face value rate #{from}/#{to} failed: #{e.class}: #{e.message}")
          nil
        end

        def rate_on(from, to, date)
          dated = (@rates[[ from, to ]] ||= load_rates(from, to))
          # The last rate on or before the date.
          position = (dated.bsearch_index { |(rate_date, _)| rate_date > date } || dated.size) - 1
          return nil if position.negative?

          rate_date, rate = dated[position]
          rate if rate_date >= date - LOOKBACK_DAYS
        end

        def load_rates(from, to)
          ExchangeRate.import_provider_rates(from: from, to: to, start_date: start_date, end_date: end_date) unless covered?(from, to)
          stored(from, to)
        rescue StandardError => e
          Rails.logger.warn("Bullion face value rates #{from}/#{to} failed: #{e.class}: #{e.message}")
          stored(from, to)
        end

        def covered?(from, to)
          dates = stored(from, to).map(&:first)
          dates.any? && dates.first <= start_date && dates.last >= end_date - LOOKBACK_DAYS
        end

        # [date, rate] pairs, oldest first. A pair stored only the other way
        # round counts too, inverted.
        def stored(from, to)
          window = (start_date - LOOKBACK_DAYS)..end_date
          direct = ExchangeRate.where(from_currency: from, to_currency: to, date: window).pluck(:date, :rate)
          inverse = ExchangeRate.where(from_currency: to, to_currency: from, date: window).pluck(:date, :rate)
            .select { |(_, rate)| ExchangeRate.valid_rate?(rate) }
            .map { |(date, rate)| [ date, 1 / rate.to_d ] }

          by_date = inverse.to_h.merge(direct.to_h)
          by_date.select { |_, rate| ExchangeRate.valid_rate?(rate) }.sort_by(&:first)
        end
    end
end
