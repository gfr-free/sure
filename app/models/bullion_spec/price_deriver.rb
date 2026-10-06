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

    Security.find_or_create_by!(ticker: attrs[:ticker].upcase, exchange_operating_mic: attrs[:exchange_operating_mic]&.upcase) do |security|
      security.price_provider = attrs[:price_provider]
    end
  rescue ActiveRecord::RecordNotUnique
    Security.find_by(ticker: attrs[:ticker].upcase, exchange_operating_mic: attrs[:exchange_operating_mic]&.upcase)
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
      reference.import_provider_prices(start_date: start_date, end_date: end_date) unless reference.offline?

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

    # From the first trade of any piece of this metal, so history is complete.
    def start_date_for(specs)
      @start_date ||
        Trade.with_entry.where(security_id: specs.map(&:security_id)).minimum(:date) ||
        DEFAULT_LOOKBACK_DAYS.days.ago.to_date
    end
end
