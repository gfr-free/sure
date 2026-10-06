require "test_helper"

class BullionCatalogTest < ActiveSupport::TestCase
  test "shipped catalogue loads with valid metals, forms and positive weights" do
    products = BullionCatalog.products

    assert products.any?
    products.each do |product|
      assert_includes BullionSpec::METALS, product.metal
      assert_includes BullionCatalog::FORMS, product.form
      assert product.sizes.all? { |size| size.fine_weight_grams.positive? }, "#{product.key} has a non-positive size"
    end
  end

  test "ounce sizes convert to fine grams" do
    krugerrand = BullionCatalog.find(:krugerrand)

    assert_equal BigDecimal("31.1035"), krugerrand.size("1oz").fine_weight_grams
    assert_equal BigDecimal("3.1103"), krugerrand.size("1-10oz").fine_weight_grams
    assert_equal BigDecimal("7.3224"), BullionCatalog.find(:sovereign).size("full").fine_weight_grams
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
    first = BullionCatalog.security_for(:silver_bar, "1kg")

    assert_no_difference [ "Security.count", "BullionSpec.count" ] do
      assert_equal first, BullionCatalog.security_for("silver_bar", "1kg")
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
  end

  test "load_products rejects invalid entries" do
    valid = { "key" => "x", "name" => "X", "metal" => "XAU", "form" => "coin", "sizes" => [ { "key" => "1oz", "label" => "1 oz", "fine_oz" => 1 } ] }

    assert_equal 1, BullionCatalog.load_products("products" => [ valid ]).size
    assert_raises(ArgumentError) { BullionCatalog.load_products("products" => [ valid.merge("metal" => "CU") ]) }
    assert_raises(ArgumentError) { BullionCatalog.load_products("products" => [ valid.merge("form" => "jewelry") ]) }
    assert_raises(ArgumentError) { BullionCatalog.load_products("products" => [ valid, valid ]) }
    assert_raises(ArgumentError) { BullionCatalog.load_products("products" => [ valid.merge("sizes" => []) ]) }
    assert_raises(ArgumentError) do
      BullionCatalog.load_products("products" => [ valid.merge("sizes" => [ { "key" => "a", "label" => "A" } ]) ])
    end
    assert_raises(ArgumentError) do
      BullionCatalog.load_products("products" => [ valid.merge("sizes" => [ { "key" => "a", "label" => "A", "fine_grams" => 0 } ]) ])
    end
  end
end
