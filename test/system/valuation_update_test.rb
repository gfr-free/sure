require "application_system_test_case"

class ValuationUpdateTest < ApplicationSystemTestCase
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)

    @entry = entries(:valuation)
  end

  test "updating a balance closes the confirm dialog and says balances are recalculating" do
    visit account_url(@entry.account, tab: "activity")

    click_link @entry.name

    within "#drawer" do
      fill_in "entry[amount]", with: "6000"
      # Leave the field so its operator bar no longer covers the submit button.
      find("label", text: I18n.t("valuations.show.date_label")).click
      click_button I18n.t("valuations.show.update_value")
    end

    within "#modal" do
      click_button I18n.t("valuations.confirm_update.update")
    end

    within "#notification-tray" do
      assert_text I18n.t("valuations.update.balances_recalculating")
    end
    assert_no_selector "#modal dialog"
  end
end
