require "test_helper"

class BullionSpecTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "create_custom! creates a family-owned offline security" do
    spec = nil

    assert_difference [ "Security.count", "BullionSpec.count" ], 1 do
      spec = BullionSpec.create_custom!(family: @family, name: "Vreneli 20 Fr.", metal: "XAU", fine_weight_grams: "5.8064")
    end

    assert spec.custom?
    assert_equal @family, spec.family
    assert_includes @family.bullion_specs, spec
    assert_equal "Vreneli 20 Fr.", spec.security.name
    assert spec.security.offline?
    assert_equal "precious_metal", spec.security.asset_sub_class
    assert spec.security.ticker.start_with?("BULLION-CUSTOM-")
  end

  test "create_custom! saves nothing when invalid" do
    assert_no_difference [ "Security.count", "BullionSpec.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        BullionSpec.create_custom!(family: @family, name: "", metal: "XAU", fine_weight_grams: 5)
      end
      assert_raises(ActiveRecord::RecordInvalid) do
        BullionSpec.create_custom!(family: @family, name: "Coin", metal: "CU", fine_weight_grams: 5)
      end
      assert_raises(ActiveRecord::RecordInvalid) do
        BullionSpec.create_custom!(family: @family, name: "Coin", metal: "XAG", fine_weight_grams: 0)
      end
    end
  end

  test "catalogue specs need catalogue keys and custom specs must not have them" do
    catalog_spec = BullionSpec.new(security: securities(:aapl), metal: "XAU", fine_weight_grams: 1)
    assert_not catalog_spec.valid?
    assert catalog_spec.errors[:catalog_key].any?

    custom_spec = BullionSpec.new(security: securities(:aapl), family: @family, metal: "XAU", fine_weight_grams: 1, catalog_key: "krugerrand", size_key: "1oz")
    assert_not custom_spec.valid?
    assert custom_spec.errors[:catalog_key].any?
  end

  test "database enforces metal and positive weight" do
    spec = BullionCatalog.security_for(:krugerrand, "1oz").bullion_spec

    assert_raises(ActiveRecord::CheckViolation) do
      BullionSpec.transaction(requires_new: true) { spec.update_columns(metal: "CU") }
    end
    assert_raises(ActiveRecord::CheckViolation) do
      BullionSpec.transaction(requires_new: true) { spec.update_columns(fine_weight_grams: 0) }
    end
  end

  test "destroying a custom spec removes its security, a catalogue spec keeps it" do
    custom = BullionSpec.create_custom!(family: @family, name: "My coin", metal: "XAG", fine_weight_grams: 10)
    catalog = BullionCatalog.security_for(:krugerrand, "1oz").bullion_spec

    assert_difference "Security.count", -1 do
      custom.destroy!
    end
    assert_no_difference "Security.count" do
      catalog.destroy!
    end
  end

  test "a custom coin with trades cannot be destroyed" do
    spec = BullionSpec.create_custom!(family: @family, name: "My coin", metal: "XAU", fine_weight_grams: 3)
    account = accounts(:investment)
    account.entries.create!(
      date: Date.current, name: "Buy coin", amount: 300, currency: account.currency,
      entryable: Trade.new(security: spec.security, qty: 1, price: 300, currency: account.currency)
    )

    assert_no_difference [ "Security.count", "BullionSpec.count" ] do
      assert_not spec.destroy
    end
    assert spec.errors[:base].any?
  end

  test "destroying a family removes its custom coins but not the catalogue" do
    family = Family.create!(name: "Coin collectors", currency: "EUR")
    BullionSpec.create_custom!(family: family, name: "My coin", metal: "XAU", fine_weight_grams: 3)
    BullionCatalog.security_for(:panda, "30g")

    family.destroy!

    assert_equal 0, BullionSpec.custom.count
    assert_equal 1, BullionSpec.catalog.count
  end
end
