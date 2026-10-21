require "test_helper"

class BullionSpec::PriceDeriverTest < ActiveSupport::TestCase
  setup do
    @reference = Security.create!(ticker: "GC=F", exchange_operating_mic: "CMX", name: "Gold futures", offline: true)
    Setting.bullion_reference_provider = "yahoo_finance"

    @coin = BullionCatalog.security_for(:krugerrand, "1-2oz")
    @bar = BullionCatalog.bar_security_for(:gold_bar, 1, "oz")

    @reference.prices.create!(date: 2.days.ago.to_date, price: 4000, currency: "USD")
    @reference.prices.create!(date: 1.day.ago.to_date, price: 4100, currency: "USD", provisional: true)
  end

  teardown do
    Setting.bullion_reference_provider = nil
  end

  test "derives prices from fine ounces times the reference price" do
    BullionSpec::PriceDeriver.new.derive_all

    coin_price = @coin.prices.find_by!(date: 2.days.ago.to_date)
    assert_equal "USD", coin_price.currency
    assert_in_delta 2000, coin_price.price, 0.01

    bar_prices = @bar.prices.order(:date).pluck(:price, :provisional)
    assert_equal 2, bar_prices.size
    assert_in_delta 4000, bar_prices.first.first, 0.01
    assert_equal [ false, true ], bar_prices.map(&:last)
  end

  test "a coin is never priced below its face value in the reference currency" do
    # 20 USD face value, 1 g silver: the metal is worth far less.
    coin = BullionSpec.create_custom!(family: families(:dylan_family), name: "Dollar", metal: "XAU",
                                      fine_weight_grams: BigDecimal("0.0031"), face_value: 20, face_value_currency: "USD").security

    BullionSpec::PriceDeriver.new.derive_all

    assert_equal [ 20 ], coin.prices.pluck(:price).uniq.map(&:to_i)
    # Above the face value, the metal value counts.
    assert_in_delta 2000, @coin.prices.find_by!(date: 2.days.ago.to_date).price, 0.01
  end

  test "a face value in another currency is converted at each day's rate" do
    coin = BullionSpec.create_custom!(family: families(:dylan_family), name: "20 Euro", metal: "XAU",
                                      fine_weight_grams: BigDecimal("0.0031"), face_value: 20, face_value_currency: "EUR").security
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: 2.days.ago.to_date, rate: 1.1)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: 1.day.ago.to_date, rate: 1.2)

    BullionSpec::PriceDeriver.new.derive_all

    assert_in_delta 22, coin.prices.find_by!(date: 2.days.ago.to_date).price, 0.0001
    assert_in_delta 24, coin.prices.find_by!(date: 1.day.ago.to_date).price, 0.0001
    assert_equal [ "USD" ], coin.prices.pluck(:currency).uniq
  end

  test "a day without a rate takes the last rate from up to five days before" do
    coin = BullionSpec.create_custom!(family: families(:dylan_family), name: "20 Euro", metal: "XAU",
                                      fine_weight_grams: BigDecimal("0.0031"), face_value: 20, face_value_currency: "EUR").security
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: 4.days.ago.to_date, rate: 1.1)

    BullionSpec::PriceDeriver.new.derive_all

    assert_equal [ 22 ], coin.prices.pluck(:price).map(&:to_i).uniq
  end

  test "without any exchange rate the metal value stands and the gap is logged" do
    coin = BullionSpec.create_custom!(family: families(:dylan_family), name: "20 Euro", metal: "XAU",
                                      fine_weight_grams: BigDecimal("0.0031"), face_value: 20, face_value_currency: "EUR").security
    # None stored, so the provider is asked once; it has none either.
    ExchangeRate.expects(:import_provider_rates).with(has_entries(from: "EUR", to: "USD")).once.returns(0)

    assert_difference -> { DebugLogEntry.where("message LIKE ?", "%exchange rate%").count }, 1 do
      BullionSpec::PriceDeriver.new.derive_all
    end

    # Fine ounces times 4000 USD, not a 1:1 guess of 20 USD.
    metal_value = BigDecimal("0.0031") / BullionSpec::TROY_OUNCE_GRAMS * 4000
    assert_in_delta metal_value, coin.prices.find_by!(date: 2.days.ago.to_date).price, 0.0001
  end

  test "a rate older than five days is not used" do
    coin = BullionSpec.create_custom!(family: families(:dylan_family), name: "20 Euro", metal: "XAU",
                                      fine_weight_grams: BigDecimal("0.0031"), face_value: 20, face_value_currency: "EUR").security
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: 8.days.ago.to_date, rate: 1.1)
    ExchangeRate.stubs(:import_provider_rates).returns(0)

    BullionSpec::PriceDeriver.new(start_date: 8.days.ago.to_date).derive_all

    assert coin.prices.pluck(:price).all? { |price| price < 1 }
  end

  test "a rate stored only the other way round is inverted" do
    coin = BullionSpec.create_custom!(family: families(:dylan_family), name: "20 Euro", metal: "XAU",
                                      fine_weight_grams: BigDecimal("0.0031"), face_value: 20, face_value_currency: "EUR").security
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: 2.days.ago.to_date, rate: 0.8)
    ExchangeRate.stubs(:import_provider_rates).returns(0)

    BullionSpec::PriceDeriver.new.derive_all

    assert_in_delta 25, coin.prices.find_by!(date: 2.days.ago.to_date).price, 0.0001
  end

  test "a face value far below the metal value loads no rate history" do
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: 1.day.ago.to_date, rate: 0.73)
    maple = BullionCatalog.security_for(:maple_leaf, "1oz")
    ExchangeRate.expects(:import_provider_rates).never

    BullionSpec::PriceDeriver.new.derive_all

    assert_in_delta 4000, maple.prices.find_by!(date: 2.days.ago.to_date).price, 0.01
  end

  test "overwrites earlier derived prices when the reference changes" do
    BullionSpec::PriceDeriver.new.derive_all
    @reference.prices.find_by!(date: 1.day.ago.to_date).update!(price: 4200, provisional: false)

    assert_no_difference "Security::Price.count" do
      BullionSpec::PriceDeriver.new.derive_all
    end

    price = @coin.prices.find_by!(date: 1.day.ago.to_date)
    assert_in_delta 2100, price.price, 0.01
    assert_not price.provisional
  end

  test "removes derived prices in the old currency when the reference currency changes" do
    BullionSpec::PriceDeriver.new.derive_all
    @reference.prices.destroy_all
    @reference.prices.create!(date: 2.days.ago.to_date, price: 3600, currency: "EUR")

    BullionSpec::PriceDeriver.new.derive_all

    assert_equal [ "EUR" ], @coin.prices.pluck(:currency).uniq
    assert_equal 1, @coin.prices.where(date: 2.days.ago.to_date).count
  end

  test "limits derivation to the given securities" do
    BullionSpec::PriceDeriver.new(security_ids: [ @coin.id ]).derive_all

    assert @coin.prices.exists?
    assert_not @bar.prices.exists?
  end

  test "derives nothing for a metal whose reference has no prices yet" do
    silver = BullionCatalog.bar_security_for(:silver_bar, 1, "kg")

    assert_nothing_raised { BullionSpec::PriceDeriver.new.derive_all }
    assert_not silver.prices.exists?
  end

  test "imports prices for an online reference before deriving" do
    @reference.update!(offline: false)
    Setting.stubs(:enabled_securities_providers).returns([ "yahoo_finance" ])
    Security.any_instance.expects(:import_provider_prices).with(has_entries(end_date: Date.current)).once

    BullionSpec::PriceDeriver.new.derive_all
  end

  test "reference_security finds or creates the provider's symbol for a metal" do
    silver_reference = nil
    assert_difference "Security.count", 1 do
      silver_reference = BullionSpec::PriceDeriver.reference_security("XAG")
    end
    assert_equal [ "SI=F", "CMX", "yahoo_finance" ], [ silver_reference.ticker, silver_reference.exchange_operating_mic, silver_reference.price_provider ]

    assert_no_difference "Security.count" do
      assert_equal silver_reference, BullionSpec::PriceDeriver.reference_security("XAG")
    end
  end

  test "the chosen provider decides each metal's symbol" do
    Setting.bullion_reference_provider = "twelve_data"

    assert_equal [ "XAU/USD", nil ], BullionSpec::PriceDeriver.reference_symbol("XAU")
    reference = BullionSpec::PriceDeriver.reference_security("XPD")
    assert_equal [ "XPD/USD", "twelve_data" ], [ reference.ticker, reference.price_provider ]
  end

  test "an unknown provider setting falls back to the default" do
    Setting.bullion_reference_provider = "nonexistent"

    assert_equal "yahoo_finance", BullionSpec::PriceDeriver.reference_provider
    assert_equal [ "GC=F", "CMX" ], BullionSpec::PriceDeriver.reference_symbol("XAU")
  end

  test "offers only providers with known symbols" do
    assert_equal %w[yahoo_finance twelve_data].sort, BullionSpec::PriceDeriver.available_reference_providers.sort
  end

  test "logs a warning instead of importing when the reference provider is not enabled" do
    @reference.update!(offline: false, price_provider: "yahoo_finance")
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])
    Security.any_instance.expects(:import_provider_prices).never

    assert_difference -> { DebugLogEntry.where(level: "warn", source: "BullionSpec::PriceDeriver").count }, 1 do
      BullionSpec::PriceDeriver.new.derive_all
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "XAU", entry.metadata["metal"]
    assert_equal "yahoo_finance", entry.metadata["price_provider"]
    assert @coin.prices.exists?, "derives from the prices the reference already has"
  end

  test "reference_provider_disabled? reports a chosen provider that is not enabled" do
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])
    assert BullionSpec::PriceDeriver.reference_provider_disabled?

    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data", "yahoo_finance" ])
    assert_not BullionSpec::PriceDeriver.reference_provider_disabled?
  end

  test "reference_security applies a changed provider to an existing reference" do
    @reference.update!(price_provider: "twelve_data", offline: true, offline_reason: "provider_disabled")
    Setting.stubs(:enabled_securities_providers).returns([ "yahoo_finance" ])

    assert_no_difference "Security.count" do
      BullionSpec::PriceDeriver.reference_security("XAU")
    end

    @reference.reload
    assert_equal "yahoo_finance", @reference.price_provider
    assert_not @reference.offline?
  end

  test "reference_security keeps a reference offline while the new provider is not enabled" do
    @reference.update!(price_provider: "twelve_data", offline: true, offline_reason: "provider_disabled")
    Setting.stubs(:enabled_securities_providers).returns([])

    BullionSpec::PriceDeriver.reference_security("XAU")

    @reference.reload
    assert_equal "yahoo_finance", @reference.price_provider
    assert_equal "provider_disabled", @reference.offline_reason
  end

  test "reference_security keeps a manually offline reference offline" do
    @reference.update!(price_provider: "twelve_data", offline: true, offline_reason: nil)

    BullionSpec::PriceDeriver.reference_security("XAU")

    @reference.reload
    assert_equal "yahoo_finance", @reference.price_provider
    assert @reference.offline?
  end

  test "ships Yahoo Finance as the default provider" do
    Setting.bullion_reference_provider = nil

    assert_equal "yahoo_finance", Setting.bullion_reference_provider
  end
end
