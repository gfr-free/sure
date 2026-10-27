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

  test "fine weight is kept to four decimals and must fit between zero and 100 kg" do
    spec = BullionSpec.create_custom!(family: @family, name: "Ducat", metal: "XAU", fine_weight_grams: BigDecimal("3.44123456789"))
    assert_equal BigDecimal("3.4412"), spec.reload.fine_weight_grams

    assert_no_difference [ "Security.count", "BullionSpec.count" ] do
      # Rounds to zero in the column, so it must not reach the database check.
      assert_raises(ActiveRecord::RecordInvalid) do
        BullionSpec.create_custom!(family: @family, name: "Tiny", metal: "XAU", fine_weight_grams: BigDecimal("0.00001"))
      end
      # A typo such as "1.234,5" with the comma turned into a dot.
      assert_raises(ActiveRecord::RecordInvalid) do
        BullionSpec.create_custom!(family: @family, name: "Typo", metal: "XAU", fine_weight_grams: "1.234.5")
      end
      # Would overflow the column.
      assert_raises(ActiveRecord::RecordInvalid) do
        BullionSpec.create_custom!(family: @family, name: "Huge", metal: "XAU", fine_weight_grams: BigDecimal("123456789012345"))
      end
    end
  end

  test "a custom coin keeps its face value and currency" do
    spec = BullionSpec.create_custom!(family: @family, name: "20 Euro Silber", metal: "XAG", fine_weight_grams: "16.65",
                                      face_value: "20.123456", face_value_currency: " eur ")

    spec.reload
    assert_equal BigDecimal("20.1235"), spec.face_value
    assert_equal "EUR", spec.face_value_currency
    assert_equal Money.new(BigDecimal("20.1235"), "EUR"), spec.nominal_value
  end

  test "a custom coin without a face value drops the currency the form posts" do
    spec = BullionSpec.create_custom!(family: @family, name: "Ducat", metal: "XAU", fine_weight_grams: 3.44,
                                      face_value: "", face_value_currency: "EUR")

    assert_nil spec.face_value
    assert_nil spec.face_value_currency
    assert_nil spec.nominal_value
  end

  test "rejects face values that are not a positive amount in a known currency" do
    invalid = [
      [ "0", "EUR" ], [ "-20", "EUR" ], [ "abc", "EUR" ], [ "0.00001", "EUR" ],
      [ "1000000001", "EUR" ], [ "20", "XYZ" ], [ "20", "" ], [ "20", nil ]
    ]

    assert_no_difference [ "Security.count", "BullionSpec.count" ] do
      invalid.each do |value, currency|
        assert_raises(ActiveRecord::RecordInvalid, "#{value.inspect} #{currency.inspect}") do
          BullionSpec.create_custom!(family: @family, name: "Coin", metal: "XAG", fine_weight_grams: 10,
                                     face_value: value, face_value_currency: currency)
        end
      end
    end
  end

  test "catalogue coins take their face value from the catalogue, not the record" do
    spec = BullionCatalog.security_for(:philharmonic, "1oz").bullion_spec
    assert_equal Money.new(100, "EUR"), spec.nominal_value
    assert_nil BullionCatalog.security_for(:krugerrand, "1oz").bullion_spec.nominal_value
    assert_nil BullionCatalog.bar_security_for(:silver_bar, 1, "kg").bullion_spec.nominal_value

    spec.face_value = 5
    spec.face_value_currency = "EUR"
    assert_not spec.valid?
    assert spec.errors[:face_value].any?
  end

  test "database requires a positive face value together with its currency" do
    spec = BullionSpec.create_custom!(family: @family, name: "Coin", metal: "XAG", fine_weight_grams: 10)

    assert_raises(ActiveRecord::CheckViolation) do
      BullionSpec.transaction(requires_new: true) { spec.update_columns(face_value: 20) }
    end
    assert_raises(ActiveRecord::CheckViolation) do
      BullionSpec.transaction(requires_new: true) { spec.update_columns(face_value: -1, face_value_currency: "EUR") }
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

  test "a custom coin with holdings cannot be destroyed" do
    spec = BullionSpec.create_custom!(family: @family, name: "My coin", metal: "XAU", fine_weight_grams: 3)
    account = accounts(:investment)
    account.holdings.create!(security: spec.security, date: Date.current, qty: 1, price: 300, amount: 300, currency: account.currency)

    assert_no_difference [ "Security.count", "BullionSpec.count" ] do
      assert_not spec.destroy
    end
  end

  test "a custom coin used as a provider security cannot be destroyed" do
    spec = BullionSpec.create_custom!(family: @family, name: "My coin", metal: "XAU", fine_weight_grams: 3)
    account = accounts(:investment)
    account.holdings.create!(
      security: securities(:aapl), provider_security: spec.security,
      date: 3.years.ago.to_date, qty: 1, price: 300, amount: 300, currency: account.currency
    )

    assert_no_difference [ "Security.count", "BullionSpec.count" ] do
      assert_not spec.destroy
    end
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
