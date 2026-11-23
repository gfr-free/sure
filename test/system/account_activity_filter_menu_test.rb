require "application_system_test_case"

# The activity Filter menu loads when its popover opens. Until then the active
# filters ride along in the search form as hidden inputs.
class AccountActivityFilterMenuTest < ApplicationSystemTestCase
  include EntriesTestHelper
  include ActionView::RecordIdentifier

  setup do
    sign_in users(:family_admin)
    @account = accounts(:depository)
    @food = create_transaction(account: @account, name: "Grocery run", category: categories(:food_and_drink))
    @other = create_transaction(account: @account, name: "Grocery refund", category: nil)
    page.current_window.resize_to(1280, 900)
  end

  test "a search typed before the menu opens keeps the active filters" do
    visit account_url(@account, tab: "activity", q: { categories: [ categories(:food_and_drink).name ] })
    assert_selector "##{dom_id(@food)}"
    assert_no_selector "##{dom_id(@other)}"
    assert_no_selector "#transaction-filters-menu", visible: :all

    fill_in "q[search]", with: "Grocery"
    find_field("q[search]").send_keys(:enter)

    assert_selector "#account-activity-filters li", text: "Grocery"
    assert_selector "#account-activity-filters li", text: categories(:food_and_drink).name
    assert_selector "##{dom_id(@food)}"
    assert_no_selector "##{dom_id(@other)}"
  end

  test "the menu loads with the active filters checked and applies a change" do
    visit account_url(@account, tab: "activity", q: { categories: [ categories(:food_and_drink).name ] })

    find("#activity-filters-button").click

    within "#transaction-filters-menu" do
      find("button[data-id='category_filter']").click
      assert_checked_field categories(:food_and_drink).name, visible: :all
      uncheck categories(:food_and_drink).name, allow_label_click: true
      click_button "Apply"
    end

    assert_selector "##{dom_id(@food)}"
    assert_selector "##{dom_id(@other)}"
  end

  test "opening the menu moves focus into it once it loads" do
    visit account_url(@account, tab: "activity")

    find("#activity-filters-button").click

    assert_selector "#transaction-filters-menu"
    focused_inside = -> { page.evaluate_script(%(document.querySelector("#transaction-filters-menu").contains(document.activeElement))) }
    wait_until(timeout: 5) { focused_inside.call }
    assert focused_inside.call, "focus moved into the loaded menu"
  end

  test "the menu loads again after a morph refresh, opened before or not" do
    visit account_url(@account, tab: "activity")
    find("#activity-filters-button").click
    assert_selector "#transaction-filters-menu button[data-id='category_filter']"

    morph_refresh

    find("#activity-filters-button").click unless page.has_selector?("#transaction-filters-menu", wait: 0)
    assert_selector "#transaction-filters-menu button[data-id='category_filter']"

    visit account_url(@account, tab: "activity")
    morph_refresh

    find("#activity-filters-button").click
    assert_selector "#transaction-filters-menu button[data-id='category_filter']"
  end

  private
    def morph_refresh
      page.execute_script(%(window.__morphed = false; document.addEventListener("turbo:morph", () => { window.__morphed = true }, { once: true }); Turbo.visit(location.href, { action: "replace" })))
      wait_until(timeout: 15) { page.evaluate_script("window.__morphed") }
      assert page.evaluate_script("window.__morphed"), "the refresh morphed the page"
    end
end
