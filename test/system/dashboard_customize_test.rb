require "application_system_test_case"

class DashboardCustomizeTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
  end

  test "hides a widget from the keyboard and adds it back" do
    sign_in @user
    net_worth = I18n.t("pages.dashboard.net_worth_chart.title")

    click_on I18n.t("pages.dashboard.customize.start"), match: :first
    find_button(I18n.t("pages.dashboard.customize.hide", title: net_worth)).send_keys(:enter)

    assert_no_selector "section[data-section-key='net_worth_chart']"
    assert_equal net_worth, page.evaluate_script("document.activeElement.textContent").strip

    click_on net_worth
    assert_selector "section[data-section-key='net_worth_chart']"
    assert_equal "net_worth_chart", page.evaluate_script("document.activeElement.dataset.sectionKey")

    click_on I18n.t("pages.dashboard.customize.done")
    assert_no_button I18n.t("pages.dashboard.customize.hide", title: net_worth)
  end

  test "a widget moved with the keyboard keeps its new place" do
    sign_in @user
    first, second = all("section[data-section-key]").first(2).map { |section| section["data-section-key"] }
    record_saved_section_order("dashboard-sortable")

    find("section[data-section-key='#{first}']").send_keys(:enter)
    page.send_keys(:arrow_down)
    page.send_keys(:enter)

    assert_selector "html[data-order-saved='200']"
    saved_order = @user.reload.dashboard_section_order
    assert_operator saved_order.index(second), :<, saved_order.index(first)
  end
end
