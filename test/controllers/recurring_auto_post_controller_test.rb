require "test_helper"

# The auto-post switch across the bill form, the bill page and the lists.
class RecurringAutoPostControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @series = recurring_transactions(:netflix_subscription) # on the manual depository account
    ensure_tailwind_build
  end

  test "the add form offers the switch and marks which accounts are manual" do
    get new_recurring_transaction_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "input[name='recurring_transaction[auto_post]'][type=checkbox]"
    manual_ids = JSON.parse(css_select("[data-controller='recurring-auto-post']").first["data-recurring-auto-post-manual-ids-value"])
    assert_includes manual_ids, accounts(:depository).id
    assert_not_includes manual_ids, accounts(:connected).id
  end

  test "create can switch auto-posting on for a manual account" do
    travel_to Date.new(2026, 10, 1) do
      post recurring_transactions_url, params: {
        recurring_transaction: {
          name: "Rent", amount: "800", account_id: accounts(:depository).id,
          first_due_on: "2026-10-05", frequency_preset: "monthly", auto_post: "1"
        }
      }
    end

    bill = @family.recurring_transactions.find_by!(name: "Rent")
    assert bill.auto_post?
    assert_equal Date.new(2026, 10, 1), bill.auto_post_from
  end

  test "update refuses auto-posting on a linked account" do
    patch recurring_transaction_url(@series), params: {
      recurring_transaction: { account_id: accounts(:connected).id, auto_post: "1" }
    }

    assert_response :unprocessable_entity
    assert_not @series.reload.auto_post?
  end

  test "the bill page menu switches auto-posting on and off" do
    post toggle_auto_post_recurring_transaction_url(@series)
    assert @series.reload.auto_post?
    assert_redirected_to bill_url(@series)

    post toggle_auto_post_recurring_transaction_url(@series)
    assert_not @series.reload.auto_post?
  end

  test "switching on is refused for a transfer into an account the user cannot write" do
    @series.update_columns(destination_account_id: accounts(:credit_card).id, bill_type: "transfer")
    Account.stubs(:writable_by).returns(Account.where(id: accounts(:depository).id))

    post toggle_auto_post_recurring_transaction_url(@series)

    assert_not @series.reload.auto_post?
    assert flash[:alert].present?
  end

  test "the bill page says since when it posts automatically" do
    @series.update!(auto_post: true)

    get bill_url(@series)

    assert_response :success
    assert_match I18n.t("bills.show.auto_posting_since", date: I18n.l(@series.auto_post_from, format: :long)), response.body
  end

  test "all bills can be filtered to the ones posting automatically" do
    @series.update!(auto_post: true)

    get bills_url(view: "all", q: { status: "auto_post" })

    assert_response :success
    assert_match @series.display_name, response.body
    assert_match I18n.t("bills.auto_post_pill.label"), response.body
    assert_no_match recurring_transactions(:inactive_subscription).merchant.name, response.body
  end

  test "the transaction list offers to confirm or discard a provisional post" do
    occurrence = post_provisionally!
    allocation = occurrence.allocations.sole

    get transactions_url

    assert_response :success
    assert_match I18n.t("transactions.auto_posted.pending_tooltip"), response.body
    assert_match confirm_recurring_allocation_path(allocation), response.body
    assert_match reject_recurring_allocation_path(allocation), response.body
  end

  test "the transaction list marks a confirmed post without review buttons" do
    occurrence = post_provisionally!
    allocation = occurrence.allocations.sole
    RecurringTransaction::Allocator.new(occurrence).confirm_posted!(allocation)

    get transactions_url

    assert_response :success
    assert_match I18n.t("transactions.transaction.auto_posted_tooltip"), response.body
    assert_no_match confirm_recurring_allocation_path(allocation), response.body
  end

  test "the bills review queue lists a provisional post" do
    post_provisionally!

    get bills_url

    assert_response :success
    assert_match I18n.t("bills.index.auto_posted_confirm"), response.body
    assert_match I18n.t("bills.index.auto_posted_discard"), response.body
  end

  test "confirming a provisional post clears its review" do
    occurrence = post_provisionally!

    post confirm_recurring_allocation_url(occurrence.allocations.sole), headers: { "HTTP_REFERER" => transactions_url }

    assert_redirected_to transactions_path
    assert_equal I18n.t("recurring_allocations.confirm_posted.success"), flash[:notice]
    assert occurrence.reload.paid?
    assert_not occurrence.allocations.sole.pending_review?
    assert occurrence.allocations.sole.from_auto_posted?
  end

  test "discarding a provisional post deletes the entry and skips the date" do
    occurrence = post_provisionally!
    entry = occurrence.allocations.sole.entry

    assert_difference -> { Entry.count }, -1 do
      post reject_recurring_allocation_url(occurrence.allocations.sole), headers: { "HTTP_REFERER" => transactions_url }
    end

    assert_redirected_to transactions_path
    assert_not Entry.exists?(entry.id)
    assert occurrence.reload.skipped?
    assert_equal I18n.t("recurring_allocations.discard.success"), flash[:notice]
  end

  test "a read-only share cannot discard a provisional post" do
    occurrence = post_provisionally!
    allocation = occurrence.allocations.sole
    Account.stubs(:writable_by).returns(Account.none)

    assert_no_difference -> { Entry.count } do
      post reject_recurring_allocation_url(allocation)
    end

    assert_response :not_found
    assert occurrence.reload.allocations.sole.pending_review?
  end

  test "a read-only share sees a provisional post without review buttons" do
    occurrence = post_provisionally!
    Account.stubs(:writable_by).returns(Account.none)

    get transactions_url

    assert_response :success
    assert_match I18n.t("transactions.auto_posted.pending_tooltip"), response.body
    assert_no_match confirm_recurring_allocation_path(occurrence.allocations.sole), response.body
  end

  private
    def post_provisionally!
      @series.update!(auto_post: true)
      occurrence = @series.recurring_occurrences.create!(family: @family, original_due_on: Date.current - 40,
                                                         due_on: Date.current, currency: "USD")
      @series.update_columns(auto_post_from: Date.current)
      RecurringTransaction::Poster.new(@family, today: Date.current).post_due!
      assert occurrence.reload.allocations.sole.pending_review?
      occurrence
    end
end
