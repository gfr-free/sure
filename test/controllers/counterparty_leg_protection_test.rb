require "test_helper"

# A person's clearing account is private to whoever keeps it. A member with
# full control of the bank account must not delete or see a booking on it.
class CounterpartyLegProtectionTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @owner = users(:family_admin)
    @member = users(:family_member)
    @member.update!(preferences: (@member.preferences || {}).merge("preview_features_enabled" => true))
    @person = families(:dylan_family).counterparties.create!(name: "Alice", default_currency: "USD", created_by: @owner)
    @entry = create_transaction(account: accounts(:depository), amount: 60, name: "Concert")
    @leg = Counterparty::Assignment.new(@entry).update!(@person, user: @owner)
    sign_in @member
  end

  test "removing the transfer is refused" do
    delete transfer_path(@entry.reload.transaction.transfer)

    assert Entry.exists?(@leg.id)
  end

  test "deleting the bank transaction is refused" do
    delete transaction_path(@entry)

    assert Entry.exists?(@entry.id)
    assert Entry.exists?(@leg.id)
  end

  test "bulk delete skips the booked transaction" do
    other = create_transaction(account: accounts(:depository), amount: 5)

    post transactions_bulk_deletion_path, params: { bulk_delete: { entry_ids: [ @entry.id, other.id ] } }

    assert Entry.exists?(@leg.id)
    assert_not Entry.exists?(other.id)
  end

  test "the drawer does not name the person" do
    get transaction_path(@entry)

    assert_response :success
    assert_no_match "Alice", response.body
    assert_select "form[action=?]", transaction_counterparty_path(@entry), count: 0
  end

  test "the owner can still remove the transfer" do
    sign_in @owner

    delete transfer_path(@entry.reload.transaction.transfer)

    assert_not Entry.exists?(@leg.id)
  end
end
