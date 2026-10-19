require "test_helper"

class BullionCatalogTest < ActiveSupport::TestCase
  test "shipped catalogue loads with valid metals, forms and positive weights" do
    products = BullionCatalog.products

    assert products.any?
    products.each do |product|
      assert_includes BullionSpec::METALS, product.metal
      assert_includes BullionCatalog::FORMS, product.form
      assert product.sizes.all? { |size| size.fine_weight_grams.positive? }, "#{product.key} has a non-positive size"
      assert_equal product.bar?, product.sizes.empty?, "#{product.key}: coins list sizes, bars do not"
    end
  end

  test "ounce sizes convert to fine grams" do
    krugerrand = BullionCatalog.find(:krugerrand)

    assert_equal BigDecimal("31.1035"), krugerrand.size("1oz").fine_weight_grams
    assert_equal BigDecimal("3.1103"), krugerrand.size("1-10oz").fine_weight_grams
    assert_equal BigDecimal("7.3224"), BullionCatalog.find(:sovereign).size("full").fine_weight_grams
    assert_equal BigDecimal("1.8306"), BullionCatalog.find(:sovereign).size("quarter").fine_weight_grams
  end

  test "security_for creates one offline precious metal security per product size" do
    security = nil

    assert_difference [ "Security.count", "BullionSpec.count" ], 1 do
      security = BullionCatalog.security_for(:maple_leaf, "1-2oz")
    end

    assert_equal "BULLION-MAPLE-LEAF-1-2OZ", security.ticker
    assert_equal "Maple Leaf 1/2 oz", security.name
    assert security.offline?
    assert_equal "commodity", security.asset_class
    assert_equal "precious_metal", security.asset_sub_class
    assert_nil security.price_provider

    spec = security.bullion_spec
    assert_equal "XAU", spec.metal
    assert_equal BigDecimal("15.5517"), spec.fine_weight_grams
    assert_not spec.custom?
    assert_in_delta 0.5, spec.fine_troy_ounces, 0.0001
  end

  test "security_for is idempotent" do
    first = BullionCatalog.security_for(:silver_kookaburra, "1oz")

    assert_no_difference [ "Security.count", "BullionSpec.count" ] do
      assert_equal first, BullionCatalog.security_for("silver_kookaburra", "1oz")
    end
  end

  test "security_for returns the security a concurrent request created" do
    first = BullionCatalog.security_for(:britannia, "1oz")
    BullionSpec.stubs(:catalog).returns(BullionSpec.none).then.returns(BullionSpec.where(family_id: nil))

    assert_no_difference "Security.count" do
      assert_equal first, BullionCatalog.security_for(:britannia, "1oz")
    end
  end

  test "security_for rejects unknown products and sizes" do
    assert_raises(BullionCatalog::UnknownProductError) { BullionCatalog.security_for(:unknown, "1oz") }
    assert_raises(BullionCatalog::UnknownProductError) { BullionCatalog.security_for(:krugerrand, "2oz") }
    assert_raises(BullionCatalog::UnknownProductError) { BullionCatalog.security_for(:gold_bar, "1oz") }
  end

  test "bar_security_for creates one security per bar product and weight" do
    security = nil

    assert_difference [ "Security.count", "BullionSpec.count" ], 1 do
      security = BullionCatalog.bar_security_for(:gold_bar, "250", "g")
    end

    assert_equal "BULLION-GOLD-BAR-250G", security.ticker
    assert_equal "Gold bar 250 g", security.read_attribute(:name)
    assert security.offline?

    spec = security.bullion_spec
    assert_equal "XAU", spec.metal
    assert_equal BigDecimal("250"), spec.fine_weight_grams
    assert_equal "gold_bar", spec.catalog_key
    assert_equal "250g", spec.size_key
  end

  test "bar_security_for treats the same weight in different units as one bar" do
    kilo = BullionCatalog.bar_security_for(:silver_bar, 1, "kg")

    assert_no_difference [ "Security.count", "BullionSpec.count" ] do
      assert_equal kilo, BullionCatalog.bar_security_for(:silver_bar, "1000", "g")
      assert_equal kilo, BullionCatalog.bar_security_for(:silver_bar, "1,0", "kg")
    end

    ounce = BullionCatalog.bar_security_for(:platinum_bar, 1, "oz")
    assert_equal BigDecimal("31.1035"), ounce.bullion_spec.fine_weight_grams
    assert_equal "Platinum bar 1 oz", ounce.read_attribute(:name)
    assert_equal ounce, BullionCatalog.bar_security_for(:platinum_bar, "31.1035", "g")
  end

  test "bar_security_for rejects coins, unknown units and implausible weights" do
    assert_raises(BullionCatalog::UnknownProductError) { BullionCatalog.bar_security_for(:krugerrand, 1, "oz") }
    assert_raises(BullionCatalog::UnknownProductError) { BullionCatalog.bar_security_for(:unknown, 1, "oz") }

    [ [ 1, "lb" ], [ 0, "g" ], [ -5, "g" ], [ "", "g" ], [ nil, "g" ], [ "abc", "g" ], [ 101, "kg" ] ].each do |weight, unit|
      assert_raises(BullionCatalog::InvalidWeightError, "#{weight.inspect} #{unit}") do
        BullionCatalog.bar_security_for(:gold_bar, weight, unit)
      end
    end
  end

  test "bar_label reads kilograms and troy ounces as such" do
    assert_equal "1 kg", BullionCatalog.bar_label(BigDecimal("1000"), locale: :en)
    assert_equal "1 oz", BullionCatalog.bar_label(BigDecimal("31.1035"), locale: :en)
    assert_equal "10 oz", BullionCatalog.bar_label(BigDecimal("311.0348"), locale: :en)
    assert_equal "100 g", BullionCatalog.bar_label(BigDecimal("100"), locale: :en)
    assert_equal "1500 g", BullionCatalog.bar_label(BigDecimal("1500"), locale: :en)
    assert_equal "2,5 g", BullionCatalog.bar_label(BigDecimal("2.5"), locale: :de)
  end

  test "catalogue security names follow the locale, custom coins keep theirs" do
    coin = BullionCatalog.security_for(:philharmonic, "1-2oz")
    bar = BullionCatalog.bar_security_for(:gold_bar, 1, "kg")
    custom = BullionSpec.create_custom!(family: families(:dylan_family), name: "Vreneli 20 Fr", metal: "XAU", fine_weight_grams: 5.806).security

    I18n.with_locale(:en) do
      assert_equal "Vienna Philharmonic 1/2 oz", coin.name
      assert_equal "Gold bar 1 kg", bar.name
    end

    I18n.with_locale(:de) do
      assert_equal "Wiener Philharmoniker 1/2 oz", coin.name
      assert_equal "Goldbarren 1 kg", bar.name
      assert_equal "Vreneli 20 Fr", custom.name
    end

    assert_nil BullionCatalog.localized_name("AAPL")
  end

  test "load_products rejects invalid entries" do
    valid = { "key" => "x", "name" => "X", "metal" => "XAU", "form" => "coin", "sizes" => [ { "key" => "1oz", "label" => "1 oz", "fine_oz" => 1 } ] }

    assert_equal 1, BullionCatalog.load_products("products" => [ valid ]).size
    assert_raises(ArgumentError) { BullionCatalog.load_products("products" => [ valid.merge("metal" => "CU") ]) }
    assert_raises(ArgumentError) { BullionCatalog.load_products("products" => [ valid.merge("form" => "jewelry") ]) }
    assert_raises(ArgumentError) { BullionCatalog.load_products("products" => [ valid, valid ]) }
    assert_raises(ArgumentError) { BullionCatalog.load_products("products" => [ valid.merge("sizes" => []) ]) }
    assert_equal 1, BullionCatalog.load_products("products" => [ valid.merge("form" => "bar").except("sizes") ]).size
    assert_raises(ArgumentError) { BullionCatalog.load_products("products" => [ valid.merge("form" => "bar") ]) }
    assert_raises(ArgumentError) do
      BullionCatalog.load_products("products" => [ valid.merge("sizes" => [ { "key" => "a", "label" => "A" } ]) ])
    end
    assert_raises(ArgumentError) do
      BullionCatalog.load_products("products" => [ valid.merge("sizes" => [ { "key" => "a", "label" => "A", "fine_grams" => 0 } ]) ])
    end
  end
end
