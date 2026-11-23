require "test_helper"

class Transactions::ReviewStatesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    enable_preview(@admin)
    enable_preview(@member)
    sign_in @admin
    ensure_tailwind_build
  end

  test "the owner flags a transaction from the drawer" do
    entry = create_transaction(name: "Flag me")

    patch transaction_review_state_path(entry, state: "flagged"), as: :turbo_stream

    assert_response :success
    transaction = entry.reload.transaction
    assert transaction.review_flagged?
    assert_equal @admin, transaction.review_state_changed_by
    assert_includes response.body, ActionView::RecordIdentifier.dom_id(entry, :review_state)
  end

  test "marks reviewed and resets" do
    entry = create_transaction(name: "Review me")

    patch transaction_review_state_path(entry, state: "reviewed")
    assert entry.reload.transaction.reviewed?

    patch transaction_review_state_path(entry, state: "open")
    assert_nil entry.reload.transaction.review_state
  end

  test "a full_control share may change the mark" do
    sign_in @member
    entry = create_transaction(name: "Shared checking", account: accounts(:depository))

    patch transaction_review_state_path(entry, state: "flagged")

    assert entry.reload.transaction.review_flagged?
  end

  test "a read_write share may change the mark" do
    accounts(:credit_card).account_shares.find_by!(user: @member).update!(permission: "read_write")
    sign_in @member
    entry = create_transaction(name: "Shared card", account: accounts(:credit_card))

    patch transaction_review_state_path(entry, state: "reviewed")

    assert entry.reload.transaction.reviewed?
  end

  test "a read_only share sees the mark but may not change it" do
    entry = create_transaction(name: "Read only card", account: accounts(:credit_card))
    Transaction.set_review_state!(Transaction.where(id: entry.entryable_id), "flagged", user: @admin)
    sign_in @member

    get transaction_path(entry)
    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(entry, :review_state)}" do
      assert_select "p", text: I18n.t("transactions.review_state.drawer.states.flagged")
      assert_select "form", count: 0
    end

    patch transaction_review_state_path(entry, state: "reviewed")

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert entry.reload.transaction.review_flagged?
  end

  test "a guest may not change the mark" do
    guest = @admin.family.users.create!(email: "guest-review@example.com", password: user_password_test,
                                        first_name: "Guest", last_name: "Reviewer", role: "guest",
                                        onboarded_at: 1.day.ago, preferences: { "preview_features_enabled" => true })
    entry = create_transaction(name: "Guest", account: @admin.family.accounts.create!(name: "Guest owned", balance: 0, currency: "USD", accountable: Depository.new, owner: guest))
    sign_in guest

    patch transaction_review_state_path(entry, state: "flagged")

    assert_equal I18n.t("shared.require_non_guest"), flash[:alert]
    assert_nil entry.reload.transaction.review_state
  end

  test "an account that is not shared is not found" do
    private_account = @admin.family.accounts.create!(name: "Admin only", balance: 0, currency: "USD",
                                                     accountable: Depository.new, owner: @admin)
    entry = create_transaction(name: "Private", account: private_account)
    sign_in @member

    patch transaction_review_state_path(entry, state: "flagged")

    assert_response :not_found
    assert_nil entry.reload.transaction.review_state
  end

  test "another family's transaction is not found" do
    other = families(:empty).accounts.create!(name: "Elsewhere", balance: 0, currency: "USD",
                                              accountable: Depository.new, owner: users(:empty))
    entry = create_transaction(name: "Foreign", account: other)

    patch transaction_review_state_path(entry, state: "flagged")

    assert_response :not_found
    assert_nil entry.reload.transaction.review_state
  end

  test "a split parent is reviewed through its parts" do
    entry = create_transaction(name: "Split me", amount: 100)
    entry.split!([ { name: "A", amount: 60, category_id: nil }, { name: "B", amount: 40, category_id: nil } ])

    patch transaction_review_state_path(entry, state: "flagged")

    assert_equal I18n.t("transactions.review_state.split_parent"), flash[:alert]
    assert_nil entry.reload.transaction.review_state
  end

  test "rejects an unknown state" do
    entry = create_transaction(name: "Unknown")

    patch transaction_review_state_path(entry, state: "done")

    assert_equal I18n.t("transactions.review_state.failure"), flash[:alert]
    assert_nil entry.reload.transaction.review_state
  end

  test "needs preview access" do
    disable_preview(@admin)
    entry = create_transaction(name: "No preview")

    patch transaction_review_state_path(entry, state: "flagged")

    assert_redirected_to root_path
    assert_nil entry.reload.transaction.review_state

    get transaction_path(entry)
    assert_select "##{ActionView::RecordIdentifier.dom_id(entry, :review_state)}", count: 0
  end

  test "the drawer offers the buttons to someone who may change the mark" do
    entry = create_transaction(name: "Drawer")

    get transaction_path(entry)

    assert_select "##{ActionView::RecordIdentifier.dom_id(entry, :review_state)} form", count: 2
  end

  test "the list row shows a marker on a flagged transaction" do
    entry = create_transaction(name: "Reviewstatemarker flagged")
    Transaction.set_review_state!(Transaction.where(id: entry.entryable_id), "flagged", user: @admin)

    get transactions_path(q: { search: "Reviewstatemarker" })

    assert_select "##{ActionView::RecordIdentifier.dom_id(entry)} span[aria-label='#{I18n.t("transactions.review_state.marker")}']"
  end

  test "the transactions page filters by review status" do
    flagged = create_transaction(name: "Reviewstatemarker one")
    open = create_transaction(name: "Reviewstatemarker two")
    Transaction.set_review_state!(Transaction.where(id: flagged.entryable_id), "flagged", user: @admin)

    get transactions_path(q: { search: "Reviewstatemarker", review_state: [ "flagged" ] })

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(flagged)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(open)}", count: 0
  end

  private
    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => false))
    end
end
