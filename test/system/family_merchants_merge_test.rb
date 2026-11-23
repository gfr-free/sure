require "application_system_test_case"

class FamilyMerchantsMergeTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family

    # "$&" is a String#replace pattern; the confirmation must show it verbatim.
    @target = @family.merchants.create!(name: "Coffee $& One")
    @shown = @family.merchants.create!(name: "Coffee Two")
    @hidden = @family.merchants.create!(name: "Tea House")
  end

  test "select all picks only shown merchants, skips the target and confirms the count" do
    open_merge_dialog
    choose_target "Coffee $& One"

    fill_in placeholder: I18n.t("family_merchants.merge.sources_search_placeholder"), with: "Coffee"
    check I18n.t("family_merchants.merge.select_all_visible")

    assert source_checkbox(@shown).checked?
    assert_not source_checkbox(@target).checked?
    assert_not source_checkbox(@hidden).checked?
    assert_text I18n.t("family_merchants.merge.selected_count", count: 1)

    click_on I18n.t("family_merchants.merge.submit")

    within "#confirm-dialog" do
      assert_text I18n.t("family_merchants.merge.confirm_body", count: 1, target: "Coffee $& One")
      click_on I18n.t("family_merchants.merge.confirm_accept")
    end

    assert_no_text I18n.t("family_merchants.merge.sources_label")
    assert_not FamilyMerchant.exists?(@shown.id)
    assert FamilyMerchant.exists?(@target.id)
    assert FamilyMerchant.exists?(@hidden.id)
  end

  test "unticking select all clears only the shown merchants" do
    open_merge_dialog
    source_checkbox(@hidden).check

    fill_in placeholder: I18n.t("family_merchants.merge.sources_search_placeholder"), with: "Coffee"
    check I18n.t("family_merchants.merge.select_all_visible")
    assert_text I18n.t("family_merchants.merge.selected_count", count: 3)

    uncheck I18n.t("family_merchants.merge.select_all_visible")

    assert_not source_checkbox(@target).checked?
    assert_not source_checkbox(@shown).checked?
    assert source_checkbox(@hidden).checked?
    assert_text I18n.t("family_merchants.merge.selected_count", count: 1)
  end

  private
    def open_merge_dialog
      visit family_merchants_path
      find("[data-DS--menu-target='button']", match: :first).click
      click_on I18n.t("family_merchants.index.merge")
      assert_text I18n.t("family_merchants.merge.sources_label")
    end

    def choose_target(name)
      click_on I18n.t("family_merchants.merge.select_target")
      within "[data-select-target='menu']" do
        find("[role='option']", text: name).click
      end
    end

    def source_checkbox(merchant)
      find("input[name='source_ids[]'][value='#{merchant.id}']", visible: :all)
    end
end
