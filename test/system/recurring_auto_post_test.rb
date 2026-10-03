require "application_system_test_case"

class RecurringAutoPostTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
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
    assert_text I18n.t("transactions.transaction.auto_posted")
  end

  test "the switch is off for a linked account" do
    visit edit_recurring_transaction_url(@series)

    within("[data-controller='recurring-auto-post']") do
      all("button[data-select-target='button']").first.click
      find("[data-select-target='option']", text: accounts(:connected).name).click
    end

    assert find("#recurring_transaction_auto_post", visible: :all).disabled?
    assert_text I18n.t("recurring_transactions.form.auto_post_manual_only")
  end

  test "the switch is off for a transfer into a linked account" do
    visit edit_recurring_transaction_url(@series)
    assert_not find("#recurring_transaction_auto_post", visible: :all).disabled?

    within("[data-controller='recurring-auto-post']") do
      all("button[data-select-target='button']").last.click
      find("[data-select-target='option']", text: accounts(:connected).name).click
    end

    assert find("#recurring_transaction_auto_post", visible: :all).disabled?
  end
end
