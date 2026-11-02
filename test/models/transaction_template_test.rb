require "test_helper"

class TransactionTemplateTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
  end

  test "amount is optional but must be positive when given" do
    template = @family.transaction_templates.new(name: "Rent", nature: "outflow")
    assert template.valid?

    template.amount = 0
    template.currency = "USD"
    assert_not template.valid?

    template.amount = 950
    template.currency = nil
    assert_not template.valid?, "an amount needs a currency"
  end

  test "rejects references from another family" do
    other_family = families(:empty)
    other_category = other_family.categories.create!(name: "Foreign", color: "#000000")
    other_tag = other_family.tags.create!(name: "Foreign tag")

    template = @family.transaction_templates.new(name: "Mixed", category: other_category, tags: [ other_tag ])

    assert_not template.valid?
    assert template.errors.added?(:category, :invalid)
    assert template.errors.added?(:tags, :invalid)
  end

  test "build_from_entry copies a manual transaction" do
    entry = create_transaction(
      account: accounts(:depository), name: "Groceries", amount: -42.5,
      category: categories(:food_and_drink), merchant: merchants(:amazon), tags: [ tags(:one) ]
    )

    template = TransactionTemplate.build_from_entry(entry)

    assert template.save
    assert_equal "Groceries", template.name
    assert_equal "inflow", template.nature
    assert_equal 42.5, template.amount
    assert_equal accounts(:depository), template.account
    assert_equal categories(:food_and_drink), template.category
    assert_equal merchants(:amazon), template.merchant
    assert_equal [ tags(:one) ], template.tags.to_a
  end

  test "build_from_entry leaves out a provider merchant" do
    provider_merchant = ProviderMerchant.create!(name: "Provider shop", source: "plaid", provider_merchant_id: "shop-1")
    entry = create_transaction(account: accounts(:depository), name: "Shop", amount: 10, merchant: provider_merchant)

    assert_nil TransactionTemplate.build_from_entry(entry).merchant_id
  end

  test "entry attributes leave out an account the user cannot see" do
    template = @family.transaction_templates.create!(name: "Car", account: accounts(:other_asset))

    assert_equal accounts(:other_asset), template.account_for(users(:family_admin))
    assert_nil template.account_for(users(:family_member))
    assert_nil template.entry_attributes_for(users(:family_member))[:currency]
  end

  test "entry attributes use the template currency only with an amount" do
    template = @family.transaction_templates.create!(name: "Fee", account: accounts(:depository), amount: 5, currency: "EUR")
    assert_equal "EUR", template.entry_attributes_for(users(:family_admin))[:currency]

    template.update!(amount: nil)
    assert_equal accounts(:depository).currency, template.entry_attributes_for(users(:family_admin))[:currency]
  end

  test "destroying a tag removes it from the template" do
    template = @family.transaction_templates.create!(name: "Tagged", tags: [ tags(:one) ])

    tags(:one).destroy!

    assert_empty template.reload.tags
  end
end
