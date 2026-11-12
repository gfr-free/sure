require "test_helper"

class MerchantsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @merchant = merchants(:netflix)
  end

  test "lists the merchant's transactions from every account" do
    create_transaction(account: accounts(:depository), name: "Netflix checking", merchant: @merchant)
    create_transaction(account: accounts(:credit_card), name: "Netflix card", merchant: @merchant)
    create_transaction(account: accounts(:depository), name: "Amazon order", merchant: merchants(:amazon))

    get merchant_url(@merchant)

    assert_response :success
    assert_match "Netflix checking", response.body
    assert_match "Netflix card", response.body
    assert_no_match "Amazon order", response.body
  end

  test "edit link returns to the merchant page it was opened from" do
    get merchant_url(@merchant, page: 2)

    assert_select "a[href=?]", edit_family_merchant_path(@merchant, return_to: merchant_path(@merchant, page: 2))
  end

  test "shows a provider merchant assigned to the family's transactions" do
    provider = ProviderMerchant.create!(name: "Coffee Co", source: "plaid")
    create_transaction(account: accounts(:depository), name: "Morning coffee", merchant: provider)

    get merchant_url(provider)

    assert_response :success
    assert_match "Morning coffee", response.body
  end

  test "leaves out transactions from accounts the user cannot access" do
    create_transaction(account: accounts(:investment), name: "Private Netflix", merchant: @merchant)
    create_transaction(account: accounts(:depository), name: "Shared Netflix", merchant: @merchant)

    sign_in users(:family_member)
    get merchant_url(@merchant)

    assert_response :success
    assert_match "Shared Netflix", response.body
    assert_no_match "Private Netflix", response.body
  end

  test "averages spending over purchases only" do
    create_transaction(account: accounts(:depository), name: "Netflix plan", merchant: @merchant, amount: 100)
    create_transaction(account: accounts(:depository), name: "Netflix refund", merchant: @merchant, amount: -100)

    get merchant_url(@merchant)

    assert_response :success
    assert_select "dt", text: "Average transaction" do |dt|
      assert_equal "$100.00", dt.first.next_element.text.strip
    end
  end

  test "does not show a provider merchant used only on accounts the user cannot access" do
    provider = ProviderMerchant.create!(name: "Private Co", source: "plaid")
    create_transaction(account: accounts(:investment), name: "Private purchase", merchant: provider)

    sign_in users(:family_member)
    get merchant_url(provider)

    assert_response :not_found
  end

  test "does not show another family's merchant" do
    other = families(:empty).merchants.create!(name: "Elsewhere")

    get merchant_url(other)

    assert_response :not_found
  end

  test "leaves out another merchant with the same name" do
    create_transaction(account: accounts(:depository), name: "Own Netflix", merchant: @merchant, amount: 100)
    namesake = ProviderMerchant.create!(name: @merchant.name, source: "plaid")
    create_transaction(account: accounts(:depository), name: "Bank Netflix", merchant: namesake, amount: 500)

    get merchant_url(@merchant)

    assert_response :success
    assert_match "Own Netflix", response.body
    assert_no_match "Bank Netflix", response.body
    assert_equal "1", summary_value("Total transactions")
    assert_equal "$100.00", summary_value("Total spending")
  end

  test "leaves zero-amount entries out of the average" do
    create_transaction(account: accounts(:depository), merchant: @merchant, amount: 100)
    create_transaction(account: accounts(:depository), merchant: @merchant, amount: 0)

    get merchant_url(@merchant)

    assert_equal "$100.00", summary_value("Average transaction")
  end

  test "counts a split with the same merchant in every part as one purchase" do
    parent = create_transaction(account: accounts(:depository), merchant: @merchant, amount: 100)
    parent.split!([ { name: "Plan", amount: 60 }, { name: "Extra screen", amount: 40 } ])

    get merchant_url(@merchant)

    assert_equal "$100.00", summary_value("Total spending")
    assert_equal "$100.00", summary_value("Average transaction")
  end

  test "leaves pending purchases out of spending and the average" do
    create_transaction(account: accounts(:depository), merchant: @merchant, amount: 100)
    pending = create_transaction(account: accounts(:depository), merchant: @merchant, amount: 300)
    pending.entryable.update!(extra: { "simplefin" => { "pending" => true } })

    get merchant_url(@merchant)

    assert_equal "2", summary_value("Total transactions")
    assert_equal "$100.00", summary_value("Total spending")
    assert_equal "$100.00", summary_value("Average transaction")
  end

  private
    def summary_value(label)
      value = nil
      assert_select "dt", text: label do |dt|
        value = dt.first.next_element.text.strip
      end
      value
    end
end
