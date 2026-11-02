require "test_helper"

class Import::NewAccountTypeMappingTest < ActiveSupport::TestCase
  test "suggests an account type from the account name" do
    {
      "Everyday Checking" => "Depository",
      "High Yield Savings" => "Depository",
      "Credit Union Checking" => "Depository",
      "Chase Sapphire Visa" => "CreditCard",
      "Amex Gold Card" => "CreditCard",
      "Home Mortgage" => "Loan",
      "Car Loan" => "Loan",
      "Fidelity 401(k)" => "Investment",
      "Roth IRA" => "Investment",
      "Brokerage" => "Investment",
      "Coinbase" => "Crypto",
      "Cardinal Savings" => "Depository"
    }.each do |name, expected|
      assert_equal expected, Import::NewAccountTypeMapping.suggested_type_for(name), name
    end
  end

  test "rejects values that are not account types" do
    import = families(:dylan_family).imports.create!(type: "MintImport")
    mapping = Import::NewAccountTypeMapping.new(import: import, key: "Everyday Checking")

    assert_equal "Depository", mapping.value
    assert mapping.valid?

    mapping.value = "Family"
    assert_not mapping.valid?

    mapping.value = ""
    assert_not mapping.valid?
  end
end
