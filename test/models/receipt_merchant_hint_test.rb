require "test_helper"

class ReceiptMerchantHintTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @identifier = { "kind" => "rksv", "value" => "3D0A1E2B:DEMO-KASSE-1" }
  end

  test "the latest confirmed merchant wins" do
    ReceiptMerchantHint.learn!(@family, [ @identifier ], merchants(:amazon))
    ReceiptMerchantHint.learn!(@family, [ @identifier ], merchants(:netflix))

    assert_equal 1, @family.receipt_merchant_hints.count
    assert_equal merchants(:netflix), ReceiptMerchantHint.merchant_for(@family, [ @identifier ])
  end

  test "ignores unknown kinds, blank values and a missing merchant" do
    ReceiptMerchantHint.learn!(@family, [ { "kind" => "other", "value" => "x" }, { "kind" => "tse", "value" => "" } ], merchants(:amazon))
    ReceiptMerchantHint.learn!(@family, [ @identifier ], nil)

    assert_empty @family.receipt_merchant_hints
    assert_nil ReceiptMerchantHint.merchant_for(@family, [])
  end

  test "is removed with its merchant" do
    ReceiptMerchantHint.learn!(@family, [ @identifier ], merchants(:amazon))

    merchants(:amazon).destroy!

    assert_empty @family.receipt_merchant_hints
  end
end
