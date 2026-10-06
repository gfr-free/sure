require "test_helper"

class BullionSpec::PriceDeriverTest < ActiveSupport::TestCase
  setup do
    @reference = Security.create!(ticker: "GC=F", exchange_operating_mic: "CMX", name: "Gold futures", offline: true)
    Setting.bullion_reference_securities = { "XAU" => "GC=F|CMX|" }

    @coin = BullionCatalog.security_for(:krugerrand, "1-2oz")
    @bar = BullionCatalog.security_for(:gold_bar, "1oz")

    @reference.prices.create!(date: 2.days.ago.to_date, price: 4000, currency: "USD")
    @reference.prices.create!(date: 1.day.ago.to_date, price: 4100, currency: "USD", provisional: true)
  end

  teardown do
    Setting.bullion_reference_securities = nil
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

  test "limits derivation to the given securities" do
    BullionSpec::PriceDeriver.new(security_ids: [ @coin.id ]).derive_all

    assert @coin.prices.exists?
    assert_not @bar.prices.exists?
  end

  test "skips metals without a reference security" do
    silver = BullionCatalog.security_for(:silver_bar, "1kg")

    assert_nothing_raised { BullionSpec::PriceDeriver.new.derive_all }
    assert_not silver.prices.exists?
  end

  test "imports prices for an online reference before deriving" do
    @reference.update!(offline: false)
    Security.any_instance.expects(:import_provider_prices).with(has_entries(end_date: Date.current)).once

    BullionSpec::PriceDeriver.new.derive_all
  end

  test "reference_security finds or creates the configured security" do
    Setting.bullion_reference_securities = { "XAG" => "si=f|cmx|" }

    silver_reference = nil
    assert_difference "Security.count", 1 do
      silver_reference = BullionSpec::PriceDeriver.reference_security("XAG")
    end
    assert_equal [ "SI=F", "CMX" ], [ silver_reference.ticker, silver_reference.exchange_operating_mic ]

    assert_no_difference "Security.count" do
      assert_equal silver_reference, BullionSpec::PriceDeriver.reference_security("XAG")
    end
    assert_nil BullionSpec::PriceDeriver.reference_security("XPT")
  end

  test "ships Yahoo futures as default references" do
    Setting.bullion_reference_securities = nil

    assert_equal "GC=F|CMX|yahoo_finance", Setting.bullion_reference_securities["XAU"]
    assert_equal BullionSpec::METALS.sort, Setting.bullion_reference_securities.keys.sort
  end
end
