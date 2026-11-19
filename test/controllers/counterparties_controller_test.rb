require "test_helper"

class CounterpartiesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @family = families(:dylan_family)
  end

  test "pages stay behind the preview flag" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get counterparties_path

    assert_redirected_to root_path
  end

  test "creates a person with a clearing account in the chosen currency" do
    assert_difference [ "Counterparty.count", "Account.count" ], 1 do
      post counterparties_path, params: { counterparty: { name: "Alex", default_currency: "EUR", note: "Climbing" } }
    end

    person = Counterparty.order(:created_at).last
    assert_redirected_to counterparty_path(person)
    assert_equal @user, person.created_by
    assert_equal [ "EUR" ], person.accounts.pluck(:currency)
  end

  test "a duplicate name re-renders the form" do
    @family.counterparties.create!(name: "Alex", default_currency: "USD", created_by: @user)

    assert_no_difference [ "Counterparty.count", "Account.count" ] do
      post counterparties_path, params: { counterparty: { name: "alex", default_currency: "USD" } }
    end

    assert_response :unprocessable_entity
  end

  test "index shows balances and totals" do
    person = @family.counterparties.create!(name: "Alex", default_currency: "USD", created_by: @user)
    person.clearing_account_for!("USD", user: @user).update!(balance: 30)

    get counterparties_path

    assert_response :success
    assert_select "a[href=?]", counterparty_path(person)
  end

  test "index filters open and archived people" do
    open_person = @family.counterparties.create!(name: "Open", default_currency: "USD", created_by: @user)
    open_person.clearing_account_for!("USD", user: @user).update!(balance: 30)
    settled = @family.counterparties.create!(name: "Settled", default_currency: "USD", created_by: @user)
    settled.clearing_account_for!("USD", user: @user)
    archived = @family.counterparties.create!(name: "Gone", default_currency: "USD", created_by: @user, archived_at: Time.current)

    get counterparties_path(status: "open")
    assert_select "a[href=?]", counterparty_path(open_person)
    assert_select "a[href=?]", counterparty_path(settled), count: 0

    get counterparties_path(status: "archived")
    assert_select "a[href=?]", counterparty_path(archived)
    assert_select "a[href=?]", counterparty_path(open_person), count: 0
  end

  test "someone without access to the accounts can't see the person" do
    person = @family.counterparties.create!(name: "Alex", default_currency: "USD", created_by: @user)
    person.clearing_account_for!("USD", user: @user)
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    get counterparty_path(person)

    assert_response :not_found
  end

  test "archive refuses an open balance and accepts a settled one" do
    person = @family.counterparties.create!(name: "Alex", default_currency: "USD", created_by: @user)
    account = person.clearing_account_for!("USD", user: @user)
    account.update!(balance: 10)

    patch archive_counterparty_path(person)
    assert_not person.reload.archived?

    account.update!(balance: 0)
    patch archive_counterparty_path(person)
    assert person.reload.archived?
  end

  test "forgiving books the open balance" do
    person = @family.counterparties.create!(name: "Alex", default_currency: "USD", created_by: @user)
    account = person.clearing_account_for!("USD", user: @user)
    account.update!(balance: 12)

    get new_counterparty_forgiveness_path(person, account_id: account.id)
    assert_response :success

    assert_difference -> { account.entries.where(entryable_type: "Transaction").count }, 1 do
      post counterparty_forgiveness_path(person), params: { forgiveness: { account_id: account.id, category_id: categories(:food_and_drink).id } }
    end
    assert_redirected_to counterparty_path(person)
  end
end
