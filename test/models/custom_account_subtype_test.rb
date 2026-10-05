require "test_helper"

class CustomAccountSubtypeTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "keeps only known rules and drops a tax treatment the type does not derive from its subtype" do
    custom = @family.custom_account_subtypes.create!(
      accountable_type: "Crypto",
      name: "Cold storage",
      rules: { "liquidity" => "long_term", "tax_treatment" => "tax_exempt", "made_up" => "x" }
    )

    assert_equal({ "liquidity" => "long_term" }, custom.rules)
    assert_nil custom.tax_treatment
  end

  test "rejects unknown levels, tax treatments and account types" do
    assert_not @family.custom_account_subtypes.new(accountable_type: "Depository", name: "A", rules: { "liquidity" => "soon" }).valid?
    assert_not @family.custom_account_subtypes.new(accountable_type: "Depository", name: "A", rules: { "liquidity" => "locked", "tax_treatment" => "free" }).valid?
    assert_not @family.custom_account_subtypes.new(accountable_type: "Account", name: "A", rules: { "liquidity" => "locked" }).valid?
    assert_not @family.custom_account_subtypes.new(accountable_type: "Depository", name: "", rules: { "liquidity" => "locked" }).valid?
  end

  test "names are unique per family and account type, ignoring case" do
    @family.custom_account_subtypes.create!(accountable_type: "Depository", name: "Fixed 2y", rules: { "liquidity" => "locked" })

    assert_not @family.custom_account_subtypes.new(accountable_type: "Depository", name: "fixed 2Y", rules: { "liquidity" => "locked" }).valid?
    assert @family.custom_account_subtypes.new(accountable_type: "Investment", name: "Fixed 2y", rules: { "liquidity" => "locked" }).valid?
    assert families(:empty).custom_account_subtypes.new(accountable_type: "Depository", name: "Fixed 2y", rules: { "liquidity" => "locked" }).valid?
  end

  test "a template copies the rules and name of a built-in subtype" do
    custom = CustomAccountSubtype.build_from_template(family: @family, accountable_type: "Investment", subtype: "401k")

    assert_equal "Investment", custom.accountable_type
    assert_equal Investment.long_subtype_label_for("401k"), custom.name
    assert_equal "long_term", custom.liquidity
    assert_equal :tax_deferred, custom.tax_treatment

    bare = CustomAccountSubtype.build_from_template(family: @family, accountable_type: "Depository")
    assert_nil bare.name
    assert_equal "immediate", bare.liquidity
  end

  test "changing the rules moves following accounts to the new default but keeps a manual level" do
    custom = @family.custom_account_subtypes.create!(accountable_type: "Depository", name: "Pot", rules: { "liquidity" => "short_term" })
    following = create_depository("Following", custom)
    manual = create_depository("Manual", custom)
    manual.update!(liquidity_choice: "immediate")

    custom.update!(liquidity: "long_term")

    assert_equal "long_term", following.reload.liquidity
    assert_equal "immediate", manual.reload.liquidity
  end

  test "renaming a subtype touches its accounts so cached labels refresh" do
    custom = @family.custom_account_subtypes.create!(accountable_type: "Depository", name: "Pot", rules: { "liquidity" => "locked" })
    account = create_depository("Pot account", custom)
    account.update_columns(updated_at: 1.day.ago)

    custom.update!(name: "Fixed pot")

    assert_operator account.reload.updated_at, :>, 1.hour.ago
  end

  test "deleting a subtype returns its accounts to the built-in subtype's rules" do
    custom = @family.custom_account_subtypes.create!(accountable_type: "Depository", name: "Pot", rules: { "liquidity" => "long_term" })
    account = create_depository("Pot account", custom, subtype: "cd", available_on: Date.new(2030, 1, 1))
    assert_equal "long_term", account.liquidity

    custom.destroy!

    account.reload
    assert_nil account.custom_account_subtype_id
    assert_equal "locked", account.liquidity
  end

  test "the account type cannot change while accounts use the subtype" do
    custom = @family.custom_account_subtypes.create!(accountable_type: "Depository", name: "Pot", rules: { "liquidity" => "locked" })
    create_depository("Pot account", custom)

    assert_not custom.update(accountable_type: "Investment")
  end

  private
    def create_depository(name, custom, subtype: "savings", available_on: nil)
      @family.accounts.create!(
        name: name,
        balance: 100,
        currency: "USD",
        accountable: Depository.new(subtype: subtype),
        custom_account_subtype: custom,
        available_on: available_on
      )
    end
end
