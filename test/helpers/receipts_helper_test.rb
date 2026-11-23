require "test_helper"

class ReceiptsHelperTest < ActionView::TestCase
  test "amount input pads to the currency's precision without rounding stored digits" do
    receipt = Receipt.new(family: families(:dylan_family), currency: "USD")

    receipt.amount = BigDecimal("5.8")
    assert_equal "5.80", receipt_amount_input_value(receipt)

    receipt.amount = BigDecimal("12.3456")
    assert_equal "12.3456", receipt_amount_input_value(receipt)

    receipt.amount = BigDecimal("123456789012345.1234")
    assert_equal "123456789012345.1234", receipt_amount_input_value(receipt)

    receipt.currency = "JPY"
    receipt.amount = BigDecimal("1200")
    assert_equal "1200", receipt_amount_input_value(receipt)
  end
end
