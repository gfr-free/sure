require "test_helper"

class Transactions::CounterpartiesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @family = families(:dylan_family)
    @person = @family.counterparties.create!(name: "Alex", default_currency: "USD", created_by: @user)
    @entry = create_transaction(account: accounts(:depository), amount: 60, name: "Concert")
  end

  test "assigns the transaction to a person" do
    patch transaction_counterparty_path(@entry), params: { transaction_counterparty: { counterparty_id: @person.id } }

    assert_redirected_to transactions_path
    assert_equal @person, Counterparty::Assignment.new(@entry.reload).counterparty
  end

  test "an empty choice releases it" do
    Counterparty::Assignment.new(@entry).update!(@person, user: @user)

    patch transaction_counterparty_path(@entry), params: { transaction_counterparty: { counterparty_id: "" } }

    assert_nil Counterparty::Assignment.new(@entry.reload).counterparty
    assert_equal "standard", @entry.transaction.kind
  end

  test "a person of another family is refused" do
    stranger = families(:empty).counterparties.create!(name: "Stranger", default_currency: "USD")

    patch transaction_counterparty_path(@entry), params: { transaction_counterparty: { counterparty_id: stranger.id } }

    assert_nil @entry.reload.transaction.transfer
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "a person whose account the user can only read is refused" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    @person.clearing_account_for!("USD", user: @user).account_shares.create!(user: member, permission: "read_only")
    sign_in member

    patch transaction_counterparty_path(@entry), params: { transaction_counterparty: { counterparty_id: @person.id } }

    assert_nil @entry.reload.transaction.transfer
  end

  test "a transaction on a read-only account can't be assigned" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    own_person = @family.counterparties.create!(name: "Sam", default_currency: "USD", created_by: member)
    card_entry = create_transaction(account: accounts(:credit_card), amount: 20)
    sign_in member

    patch transaction_counterparty_path(card_entry), params: { transaction_counterparty: { counterparty_id: own_person.id } }

    assert_nil card_entry.reload.transaction.transfer
  end

  test "the drawer shows the person field to preview users" do
    get transaction_path(@entry)

    assert_select "form[action=?]", transaction_counterparty_path(@entry)
  end

  test "the drawer hides it without the preview flag" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get transaction_path(@entry)

    assert_select "form[action=?]", transaction_counterparty_path(@entry), count: 0
  end

  test "a booked transaction opens in its own drawer, where the person can be changed" do
    Counterparty::Assignment.new(@entry).update!(@person, user: @user)
    transfer = @entry.reload.transaction.transfer

    get transactions_path(q: { search: "Concert" })

    assert_select "a[href=?]", transfer_path(transfer), count: 0
    assert_select "a[href=?]", entry_path(@entry)

    get transaction_path(@entry)
    assert_select "input[name=?]", "transaction_counterparty[counterparty_id]"
  end
end
