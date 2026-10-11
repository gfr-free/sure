# frozen_string_literal: true

require "test_helper"

# Category, merchant and tag IDs sent to the transactions API must resolve
# within the API user's family, like the web bulk update.
class Api::V1::TransactionsReferencesTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.first
    @transaction = @family.transactions.first

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )
    Redis.new.del("api_rate_limit:#{@api_key.id}")

    @other_family = families(:empty)
  end

  test "update rejects another family's category, merchant or tag" do
    foreign = {
      category_id: @other_family.categories.create!(name: "Foreign category", color: "#000000").id,
      merchant_id: @other_family.merchants.create!(name: "Foreign merchant").id,
      tag_ids: [ @other_family.tags.create!(name: "Foreign tag").id ]
    }

    foreign.each do |key, value|
      put api_v1_transaction_url(@transaction),
          params: { transaction: { key => value } },
          headers: api_headers

      assert_response :unprocessable_entity, "expected foreign #{key} to be rejected"
    end

    @transaction.reload
    assert_not_equal foreign[:category_id], @transaction.category_id
    assert_not_equal foreign[:merchant_id], @transaction.merchant_id
    assert_not_includes @transaction.tag_ids, foreign[:tag_ids].first
  end

  test "update accepts references the transaction already has" do
    @transaction.update!(category: @family.categories.first, tags: [ @family.tags.first ])

    put api_v1_transaction_url(@transaction),
        params: { transaction: { notes: "Same refs", category_id: @transaction.category_id, tag_ids: @transaction.tag_ids } },
        headers: api_headers

    assert_response :success
  end

  test "create rejects another family's category" do
    foreign_category = @other_family.categories.create!(name: "Foreign category", color: "#000000")

    assert_no_difference("Entry.count") do
      post api_v1_transactions_url,
           params: { transaction: { account_id: @account.id, name: "Foreign", amount: 5, date: Date.current, nature: "expense", category_id: foreign_category.id } },
           headers: api_headers
    end

    assert_response :unprocessable_entity
  end

  private

    def api_headers
      { "X-Api-Key" => @api_key.display_key }
    end
end
