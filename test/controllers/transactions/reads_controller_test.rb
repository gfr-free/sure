require "test_helper"

class Transactions::ReadsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @user.update_column(:transactions_read_before, 1.hour.ago)
    @checking = create_transaction(account: accounts(:depository), external_id: "r-1", source: "simplefin", name: "Checking unread")
    @card = create_transaction(account: accounts(:credit_card), external_id: "r-2", source: "simplefin", name: "Card unread")
  end

  test "without filters marks everything read" do
    post transactions_read_url

    assert_redirected_to transactions_url
    assert_empty @user.reload.unread_entries
  end

  test "with filters marks only the filtered transactions read" do
    post transactions_read_url(q: { search: "Checking" })

    unread_ids = @user.unread_entries.pluck(:id)
    assert_not_includes unread_ids, @checking.id
    assert_includes unread_ids, @card.id
  end

  test "with an account marks only that account read" do
    post transactions_read_url(account_id: accounts(:credit_card).id)

    assert_redirected_to account_url(accounts(:credit_card))
    unread_ids = @user.unread_entries.pluck(:id)
    assert_includes unread_ids, @checking.id
    assert_not_includes unread_ids, @card.id
  end

  test "an account the user cannot access is not found" do
    sign_in users(:family_member)

    post transactions_read_url(account_id: accounts(:connected).id)

    assert_response :not_found
  end

  test "another family's account is not found" do
    other_account = families(:empty).accounts.create!(
      name: "Other family", balance: 0, currency: "USD", accountable: Depository.new
    )

    post transactions_read_url(account_id: other_account.id)

    assert_response :not_found
  end
end
