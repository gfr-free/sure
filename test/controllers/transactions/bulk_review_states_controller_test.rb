require "test_helper"

class Transactions::BulkReviewStatesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    [ @admin, @member ].each { |user| user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true)) }
  end

  test "flags every selected transaction" do
    sign_in @admin
    entries = 2.times.map { |i| create_transaction(name: "Bulk #{i}") }

    post transactions_bulk_review_state_path, params: { bulk_review_state: { state: "flagged", entry_ids: entries.map(&:id) } }

    assert_redirected_to transactions_path
    assert_equal I18n.t("transactions.review_state.bulk_updated.flagged", count: 2), flash[:notice]
    entries.each { |entry| assert entry.reload.transaction.review_flagged? }
  end

  test "skips rows the user may only read" do
    sign_in @member
    writable = create_transaction(name: "Checking", account: accounts(:depository))
    read_only = create_transaction(name: "Card", account: accounts(:credit_card))

    post transactions_bulk_review_state_path, params: { bulk_review_state: { state: "reviewed", entry_ids: [ writable.id, read_only.id ] } }

    assert writable.reload.transaction.reviewed?
    assert_nil read_only.reload.transaction.review_state
  end

  test "ignores another family's transactions" do
    sign_in @admin
    other = families(:empty).accounts.create!(name: "Elsewhere", balance: 0, currency: "USD",
                                              accountable: Depository.new, owner: users(:empty))
    foreign = create_transaction(name: "Foreign", account: other)

    post transactions_bulk_review_state_path, params: { bulk_review_state: { state: "flagged", entry_ids: [ foreign.id ] } }

    assert_nil foreign.reload.transaction.review_state
  end

  test "resets the mark" do
    sign_in @admin
    entry = create_transaction(name: "Reset")
    Transaction.set_review_state!(Transaction.where(id: entry.entryable_id), "flagged", user: @admin)

    post transactions_bulk_review_state_path, params: { bulk_review_state: { state: "open", entry_ids: [ entry.id ] } }

    assert_nil entry.reload.transaction.review_state
  end

  test "leaves split parents to their parts" do
    sign_in @admin
    entry = create_transaction(name: "Split", amount: 100)
    entry.split!([ { name: "A", amount: 60, category_id: nil }, { name: "B", amount: 40, category_id: nil } ])

    post transactions_bulk_review_state_path, params: { bulk_review_state: { state: "flagged", entry_ids: [ entry.id ] } }

    assert_nil entry.reload.transaction.review_state
  end

  test "rejects an unknown state" do
    sign_in @admin
    entry = create_transaction(name: "Unknown")

    post transactions_bulk_review_state_path, params: { bulk_review_state: { state: "done", entry_ids: [ entry.id ] } }

    assert_equal I18n.t("transactions.review_state.failure"), flash[:alert]
    assert_nil entry.reload.transaction.review_state
  end

  test "needs preview access" do
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))
    sign_in @admin
    entry = create_transaction(name: "No preview")

    post transactions_bulk_review_state_path, params: { bulk_review_state: { state: "flagged", entry_ids: [ entry.id ] } }

    assert_redirected_to root_path
    assert_nil entry.reload.transaction.review_state
  end

  test "the selection bar offers the review menu only with preview access" do
    sign_in @admin
    create_transaction(name: "Menu")
    ensure_tailwind_build

    get transactions_path
    assert_select "[data-bulk-select-target=reviewMenu]"

    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))
    get transactions_path
    assert_select "[data-bulk-select-target=reviewMenu]", count: 0
  end
end
