require "application_system_test_case"

class RecurringAutoPostTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    # The chat panel leaves the transaction list too narrow for the review buttons.
    @user.update!(show_ai_sidebar: false)
    @family = @user.family
    @series = recurring_transactions(:netflix_subscription) # on the manual depository account
  end

  test "switch auto-posting on in the bill form and see the posted entry marked" do
    visit edit_recurring_transaction_url(@series)

    find("label[for='recurring_transaction_auto_post']").click
    click_button I18n.t("recurring_transactions.form.submit")

    assert_text I18n.t("recurring_transactions.update.success")
    assert @series.reload.auto_post?

    occurrence = @series.recurring_occurrences.create!(family: @family, original_due_on: Date.current - 60,
                                                       due_on: Date.current, currency: "USD")
    RecurringTransaction::Poster.new(@family, today: Date.current).post_due!
    assert occurrence.reload.paid?

    visit transactions_url
    assert_text I18n.t("transactions.auto_posted.pending")

    find("button[title='#{I18n.t("transactions.auto_posted.confirm")}']").click

    assert_text I18n.t("recurring_allocations.confirm_posted.success")
    assert_text I18n.t("transactions.transaction.auto_posted")
    assert_not occurrence.allocations.sole.reload.pending_review?
  end

  test "post an upcoming date now from its drawer" do
    occurrence = @series.recurring_occurrences.create!(family: @family, original_due_on: Date.current + 9,
                                                       due_on: Date.current + 9, currency: "USD")

    visit bill_url(@series, occurrence: occurrence.id)
    click_on I18n.t("bills.resolve")
    click_on I18n.t("recurring_occurrences.show.post_now")

    assert_text I18n.t("recurring_occurrences.post_now.success", date: I18n.l(Date.current, format: :long))
    assert occurrence.reload.paid?
    assert_equal Date.current, occurrence.allocations.sole.entry.date
  end

  test "the switch is off for a linked account" do
    visit edit_recurring_transaction_url(@series)

    within("[data-controller='recurring-auto-post']") do
      find("button[data-select-target='button']").click
      find("[data-select-target='option']", text: accounts(:connected).name).click
    end

    assert find("#recurring_transaction_auto_post", visible: :all).disabled?
    assert_text I18n.t("recurring_transactions.form.auto_post_manual_only")
  end
end
