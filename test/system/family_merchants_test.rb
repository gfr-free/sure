require "application_system_test_case"

class FamilyMerchantsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "merging merchants refreshes the list and shows the success message" do
    visit family_merchants_path
    assert_selector "tbody tr", text: "Amazon"

    find("[data-DS--menu-target='button']", match: :first).click
    click_on I18n.t("family_merchants.index.merge")

    click_on I18n.t("family_merchants.merge.select_target")
    within("[data-select-target='menu']") { find("[role='option']", text: "Netflix").click }
    find("input[name='source_ids[]'][value='#{merchants(:amazon).id}']").check
    click_on I18n.t("family_merchants.merge.submit")

    assert_selector "#notification-tray", text: I18n.t("family_merchants.perform_merge.success", count: 1)
    assert_no_selector "tbody tr", text: "Amazon"
  end
end
