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

  test "the bill drawer says since when it posts automatically and offers to stop" do
    @series.update!(auto_post: true)

    get bill_url(@series, display: "drawer"), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_match I18n.t("bills.show.auto_posting_since", date: I18n.l(@series.auto_post_from, format: :long)), response.body
    assert_select "dialog header form[action=?] [data-turbo-frame=_top]", toggle_auto_post_recurring_transaction_path(@series)
    assert_match I18n.t("bills.show.auto_post_off"), response.body
  end

  test "the bill drawer offers to switch auto-posting on for a manual account" do
    get bill_url(@series, display: "drawer"), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_match I18n.t("bills.show.auto_post_on"), response.body
    assert_no_match I18n.t("bills.show.auto_post_off"), response.body
  end

  test "the bill drawer history marks a payment Sure posted and links upcoming dates" do
    post_provisionally!
    upcoming_date = @series.schedule.occurrences_between(Date.current + 1, Date.current + 400).first
    upcoming = @series.recurring_occurrences.create!(family: @family, original_due_on: upcoming_date,
                                                     due_on: upcoming_date, currency: "USD")

    get bill_url(@series, display: "history"), headers: { "Turbo-Frame" => ActionView::RecordIdentifier.dom_id(@series, :history) }

    assert_response :success
    assert_match I18n.t("bills.detail.auto_posted"), response.body
    assert_select "a[href=?][data-turbo-frame=drawer]", recurring_occurrence_path(upcoming)
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

  test "the bills review queue asks about a date added after it was due and posts it on that date" do
    @series.update!(auto_post: true)
    @series.update_columns(auto_post_from: Date.current - 10)
    occurrence = @series.recurring_occurrences.create!(family: @family, original_due_on: Date.current - 2,
                                                       due_on: Date.current - 2, currency: "USD")

    get bills_url
    assert_response :success
    assert_match I18n.t("bills.index.late_post"), response.body
    assert_match I18n.t("bills.index.late_skip"), response.body

    post post_now_recurring_occurrence_url(occurrence, on_due_date: 1)
    allocation = occurrence.reload.allocations.sole
    assert_equal Date.current - 2, allocation.entry.date
    assert_not allocation.pending_review?
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

  test "a second confirm leaves a confirmed post marked as posted" do
    occurrence = post_provisionally!
    allocation = occurrence.allocations.sole

    2.times { post confirm_recurring_allocation_url(allocation) }

    assert allocation.reload.from_auto_posted?
    assert_not allocation.pending_review?
  end

  test "a stale discard after a confirm keeps the entry and records no rejection" do
    occurrence = post_provisionally!
    allocation = occurrence.allocations.sole
    post confirm_recurring_allocation_url(allocation)

    assert_no_difference [ -> { Entry.count }, -> { RecurringMatchRejection.count } ] do
      post reject_recurring_allocation_url(allocation), headers: { "HTTP_REFERER" => transactions_url }
    end

    assert allocation.reload.from_auto_posted?
    assert occurrence.reload.paid?
    assert_equal I18n.t("recurring_allocations.invalid"), flash[:alert]
  end

  test "discarding resyncs from the entry's own date after it was moved" do
    occurrence = post_provisionally!
    allocation = occurrence.allocations.sole
    allocation.entry.update!(date: Date.current - 5)

    Account.any_instance.expects(:sync_later).with(window_start_date: Date.current - 5).once
    post reject_recurring_allocation_url(allocation), headers: { "HTTP_REFERER" => transactions_url }
  end

  test "the bills review queue lists a provisional paycheck" do
    @series.update_columns(amount: -15.99, bill_type: "income")
    occurrence = post_provisionally!

    get bills_url

    assert_response :success
    assert_select "a[href='#{confirm_recurring_allocation_path(occurrence.allocations.sole)}']"
  end

  test "the discard button needs write access to a transfer's destination too" do
    @series.update_columns(destination_account_id: accounts(:credit_card).id, bill_type: "transfer")
    occurrence = post_provisionally!
    allocation = occurrence.allocations.sole
    Account.stubs(:writable_by).returns(Account.where(id: accounts(:depository).id))

    get transactions_url

    assert_response :success
    assert_match confirm_recurring_allocation_path(allocation), response.body
    assert_no_match reject_recurring_allocation_path(allocation), response.body
  end

  test "the edit form keeps the switch for a bill on a disabled manual account" do
    @series.update!(auto_post: true)
    accounts(:depository).disable!

    get edit_recurring_transaction_url(@series), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    manual_ids = JSON.parse(css_select("[data-controller='recurring-auto-post']").first["data-recurring-auto-post-manual-ids-value"])
    assert_includes manual_ids, accounts(:depository).id
  end

  test "the bill drawer does not offer auto-posting for a bill in another currency" do
    @series.update_columns(currency: "EUR")

    get bill_url(@series, display: "drawer"), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_no_match toggle_auto_post_recurring_transaction_path(@series), response.body
  end

  test "a read-only destination blocks edits to an auto-posting transfer" do
    @series.update_columns(destination_account_id: accounts(:credit_card).id, bill_type: "transfer", auto_post: true)
    occurrence = @series.recurring_occurrences.create!(family: @family, original_due_on: Date.current + 3,
                                                       due_on: Date.current + 3, currency: "USD")
    Account.stubs(:writable_by).returns(Account.where(id: accounts(:depository).id))

    patch recurring_transaction_url(@series), params: { recurring_transaction: { notes: "more" } }
    assert_response :not_found
    post toggle_status_recurring_transaction_url(@series)
    assert_response :not_found
    patch override_amount_recurring_occurrence_url(occurrence), params: { amount: "9999" }
    assert_response :not_found
    assert_nil occurrence.reload.expected_amount

    # Stopping it writes nothing into the destination.
    post toggle_auto_post_recurring_transaction_url(@series)
    assert_not @series.reload.auto_post?
  end

  test "a read-only destination blocks reopening a date of an auto-posting transfer through its payments" do
    @series.update_columns(destination_account_id: accounts(:credit_card).id, bill_type: "transfer", auto_post: true)
    occurrence = @series.recurring_occurrences.create!(family: @family, original_due_on: Date.current - 1,
                                                       due_on: Date.current - 1, currency: "USD")
    payment = occurrence.allocations.create!(allocated_amount: 1, currency: "USD", source: "user_confirmed", state: "confirmed")
    suggestion = @series.recurring_occurrences.create!(family: @family, original_due_on: Date.current - 2,
                                                       due_on: Date.current - 2, currency: "USD")
                        .allocations.create!(entry: entries(:transaction), allocated_amount: 1, currency: "USD",
                                             source: "auto_matched", state: "suggested")
    Account.stubs(:writable_by).returns(Account.where(id: accounts(:depository).id))

    delete recurring_allocation_url(payment)
    assert_response :not_found
    post reject_recurring_allocation_url(suggestion)
    assert_response :not_found
    assert RecurringAllocation.exists?(payment.id)
    assert RecurringAllocation.exists?(suggestion.id)
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
