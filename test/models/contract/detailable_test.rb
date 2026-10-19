require "test_helper"

class Contract::DetailableTest < ActiveSupport::TestCase
  setup do
    @insurance = contracts(:liability_insurance)
  end

  test "keeps only the fields of the contract's kind, typed" do
    @insurance.update!(details: { "insurance_line" => "liability", "sum_insured" => "10000000", "tariff" => "ignored", "deductible" => "" })

    assert_equal({ "insurance_line" => "liability", "sum_insured" => "10000000" }, @insurance.details)
    assert_equal BigDecimal("10000000"), @insurance.typed_detail(:sum_insured)
  end

  test "switching kind drops the old kind's details" do
    @insurance.update!(details: { "insurance_line" => "liability" })
    @insurance.update!(kind: "mobile", details: @insurance.details.merge("tariff" => "Unlimited"))

    assert_equal({ "tariff" => "Unlimited" }, @insurance.details)
  end

  test "rejects invalid values" do
    @insurance.details = { "sum_insured" => "-1", "insurance_line" => "spaceship" }

    assert_not @insurance.valid?
    assert @insurance.errors.key?(:details)
  end

  test "dates are validated" do
    phone = contracts(:phone_plan)
    phone.details = { "device_paid_off_on" => "not a date" }
    assert_not phone.valid?

    phone.details = { "device_paid_off_on" => "2027-02-28" }
    assert phone.valid?
    assert_equal Date.new(2027, 2, 28), phone.typed_detail(:device_paid_off_on)
  end

  test "possibly tax deductible insurance lines" do
    @insurance.details = { "insurance_line" => "liability" }
    assert @insurance.possibly_tax_deductible?

    @insurance.details = { "insurance_line" => "household" }
    assert_not @insurance.possibly_tax_deductible?
  end
end
