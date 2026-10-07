# Derives daily prices for bullion securities. Coins and bars have no market
# feed of their own; their price is the fine metal content times the price of
# a reference security per metal (Setting.bullion_reference_securities). The
# reference is an ordinary security, so its price provider is chosen exactly
# like for a stock. Derived prices keep the reference's currency.
class BullionSpec::PriceDeriver
  DEFAULT_LOOKBACK_DAYS = MarketDataImporter::SNAPSHOT_DAYS

  # The value is a combobox id ("TICKER|MIC|PROVIDER"), the same format the
  # security search uses, so the settings UI can reuse that picker.
  def self.reference_security(metal)
    combobox_id = Setting.bullion_reference_securities.to_h[metal.to_s]
    attrs = Security.parse_combobox_id(combobox_id)
    return nil if attrs[:ticker].blank?

    security = begin
      Security.find_or_create_by!(ticker: attrs[:ticker].upcase, exchange_operating_mic: attrs[:exchange_operating_mic]&.upcase) do |new_security|
        new_security.price_provider = attrs[:price_provider]
      end
    rescue ActiveRecord::RecordNotUnique
      Security.find_by(ticker: attrs[:ticker].upcase, exchange_operating_mic: attrs[:exchange_operating_mic]&.upcase)
    end

    adopt_configured_provider(security, attrs[:price_provider])
  end

  # True when the setting names a price provider that is not enabled, so the
  # reference (and every coin of that metal) would get no new prices.
  def self.reference_provider_disabled?(metal)
    provider = Security.parse_combobox_id(Setting.bullion_reference_securities.to_h[metal.to_s])[:price_provider]
    provider.present? && Setting.enabled_securities_providers.exclude?(provider)
  end

  # The reference may already exist with another provider (picked earlier or
  # held as a stock). The setting decides, so a changed provider takes effect.
  def self.adopt_configured_provider(security, provider)
    return security if security.nil? || provider.blank? || security.price_provider == provider

    attrs = { price_provider: provider }
    # Taken offline because the old provider was disabled: back online once
    # the new one is enabled, matching Settings::HostingsController.
    if security.offline_reason == "provider_disabled" && Setting.enabled_securities_providers.include?(provider)
      attrs.merge!(offline: false, offline_reason: nil, failed_fetch_count: 0, failed_fetch_at: nil)
    end
    security.update!(attrs)
    security
  end
  private_class_method :adopt_configured_provider

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
