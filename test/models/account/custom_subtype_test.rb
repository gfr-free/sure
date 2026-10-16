require "test_helper"

class Account::CustomSubtypeTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @locked_pot = @family.custom_account_subtypes.create!(
      accountable_type: "Depository", name: "Fixed 2y", rules: { "liquidity" => "locked" }
    )
  end

  test "an account takes the default availability and label of its own subtype" do
    account = create_account(Depository.new(subtype: "savings"), @locked_pot)

    assert_equal "locked", account.liquidity
    assert_not account.liquidity_manual?
    assert_equal "Fixed 2y", account.short_subtype_label
    assert_equal "Fixed 2y", account.long_subtype_label
    assert_equal "savings", account.subtype, "the built-in subtype stays underneath"
  end

  test "removing the own subtype goes back to the built-in subtype's default" do
    account = create_account(Depository.new(subtype: "savings"), @locked_pot)

    account.update!(custom_account_subtype: nil)

    assert_equal "immediate", account.reload.liquidity
  end

  test "a provider changing the built-in subtype does not override the own subtype" do
    account = create_account(Depository.new(subtype: "savings"), @locked_pot)

    account.accountable.update!(subtype: "checking")

    assert_equal "locked", account.reload.liquidity
  end

  test "an own subtype must belong to the family and fit the account type" do
    other_family = families(:empty).custom_account_subtypes.create!(
      accountable_type: "Depository", name: "Elsewhere", rules: { "liquidity" => "locked" }
    )
    investment_pot = @family.custom_account_subtypes.create!(
      accountable_type: "Investment", name: "Pension", rules: { "liquidity" => "long_term" }
    )
    account = accounts(:depository)

    account.custom_account_subtype = other_family
    assert_not account.valid?

    account.custom_account_subtype = investment_pot
    assert_not account.valid?
  end

  test "a subtype deleted in the meantime is a validation error" do
    account = accounts(:depository)
    account.custom_account_subtype_id = SecureRandom.uuid

    assert_not account.valid?
    assert account.errors.of_kind?(:custom_account_subtype, :invalid)
  end

  test "the own subtype's tax treatment decides budget exclusion" do
    retirement = @family.custom_account_subtypes.create!(
      accountable_type: "Investment", name: "Company pension", rules: { "liquidity" => "long_term", "tax_treatment" => "tax_deferred" }
    )
    taxable = @family.custom_account_subtypes.create!(
      accountable_type: "Investment", name: "Taxable wrapper", rules: { "liquidity" => "short_term", "tax_treatment" => "taxable" }
    )

    excluded = create_account(Investment.new(subtype: "brokerage"), retirement)
    included = create_account(Investment.new(subtype: "401k"), taxable)

    assert excluded.tax_advantaged?
    assert_not included.tax_advantaged?

    ids = Family.find(@family.id).tax_advantaged_account_ids
    assert_includes ids, excluded.id
    assert_not_includes ids, included.id
  end

  test "crypto keeps its own tax treatment column" do
    cold = @family.custom_account_subtypes.create!(
      accountable_type: "Crypto", name: "Cold storage", rules: { "liquidity" => "long_term" }
    )
    account = create_account(Crypto.new(subtype: "wallet", tax_treatment: "tax_exempt"), cold)

    assert_equal "long_term", account.liquidity
    assert_equal :tax_exempt, account.tax_treatment
  end

  test "the details tab names the own subtype as the source" do
    account = create_account(Depository.new(subtype: "savings"), @locked_pot)
    details = Account::RuleDetails.new(account, date: Date.new(2026, 10, 5))

    assert_equal "Fixed 2y", details.subtype_label
    assert_equal @locked_pot, details.custom_subtype
    assert_equal :custom_subtype, details.rows.find { |row| row.key == :liquidity }.source
  end

  private
    def create_account(accountable, custom)
      @family.accounts.create!(
        name: "Account #{SecureRandom.hex(3)}",
        balance: 100,
        currency: "USD",
        accountable: accountable,
        custom_account_subtype: custom
      )
    end
end
