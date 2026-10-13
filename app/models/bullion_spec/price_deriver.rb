# Derives daily prices for bullion securities. Coins and bars have no market
# feed of their own; their price is the fine metal content times the price of
# a reference security per metal. The user only picks the provider
# (Setting.bullion_reference_provider); the reference symbol for each metal
# follows from it. The reference is an ordinary security priced by that
# provider. Derived prices keep the reference's currency.
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
      rows = specs.flat_map do |spec|
        reference_prices.map do |price|
          {
            security_id: spec.security_id,
            date: price.date,
            currency: price.currency,
            price: (price.price * spec.fine_troy_ounces).round(4),
            provisional: price.provisional
          }
        end
      end
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

    # From the first trade of any piece of this metal, so history is complete.
    def start_date_for(specs)
      @start_date ||
        Trade.with_entry.where(security_id: specs.map(&:security_id)).minimum(:date) ||
        DEFAULT_LOOKBACK_DAYS.days.ago.to_date
    end
end
