require "test_helper"

class Contract::DocumentPrefillTest < ActiveSupport::TestCase
  test "seeds a contract from validated terms and ignores the rest" do
    pdf_import = PdfImport.new(family: families(:dylan_family), extracted_data: {
      "contract" => {
        "name" => "Hausratversicherung", "provider" => "Allianz", "kind" => "insurance",
        "started_on" => "2025-01-01", "minimum_term_months" => 12, "notice_period_value" => "3",
        "notice_period_unit" => "months", "notice_anchor" => "end_of_term", "renewal_period_months" => 12,
        "ends_on" => "not a date", "premium_amount" => 89.5, "premium_frequency" => "annual",
        "contract_number" => "SHOULD-NOT-APPEAR"
      }
    })
    contract = families(:dylan_family).contracts.new(owner: users(:family_admin))

    prefill = Contract::DocumentPrefill.new(pdf_import)
    prefill.apply_to(contract)

    assert_equal "Hausratversicherung", contract.name
    assert_equal "Allianz", prefill.provider_name
    assert_nil contract.merchant, "the caller maps the provider to a merchant"
    assert contract.insurance?
    assert_equal Date.new(2025, 1, 1), contract.started_on
    assert_equal 3, contract.notice_period_value
    assert_nil contract.ends_on
    assert_nil contract.contract_number
    assert_equal BigDecimal("89.5"), prefill.premium[:amount]
    assert contract.valid?
  end

  test "rejects values outside the allowed sets" do
    pdf_import = PdfImport.new(family: families(:dylan_family), extracted_data: { "contract" => { "kind" => "spaceship", "notice_period_unit" => "years" } })
    contract = Contract.new

    Contract::DocumentPrefill.new(pdf_import).apply_to(contract)

    assert contract.other?
    assert_nil contract.notice_period_unit
  end
end
