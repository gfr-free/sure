require "application_system_test_case"

# The account sidebar is cached once for every page, so the server no longer
# marks the open account in it: the layout carries the account's id and the
# browser highlights its link and opens its group, before a Turbo render shows
# the page. These tests check that from the user's side, for a full load, a
# Turbo visit, a morph refresh, and the phone drawer.
class SidebarActiveAccountTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "a full page load highlights the open account and opens its group" do
    account = accounts(:depository)
    visit account_path(account)

    assert_active_in_sidebar account
    assert_selector "#sidebar-scroll a[data-active-account]", count: 1
  end

  test "a Turbo visit moves the highlight to the account opened" do
    first, second = accounts(:depository), accounts(:investment)
    visit account_path(first)
    assert_active_in_sidebar first

    link = find("#sidebar-scroll [role=tabpanel]:not(.hidden) a[data-sidebar-account-id='#{second.id}']", visible: :all)
    link.ancestor("details").find("summary").click unless link.visible?
    find("#sidebar-scroll [role=tabpanel]:not(.hidden) a[data-sidebar-account-id='#{second.id}']").click

    assert_current_path account_path(second)
    assert_active_in_sidebar second
    assert_no_selector "#sidebar-scroll a[data-sidebar-account-id='#{first.id}'][data-active-account]", visible: :all
    assert_no_selector "#sidebar-scroll a[data-sidebar-account-id='#{first.id}'].bg-container", visible: :all
  end

  test "a morph refresh keeps the highlight and the open group" do
    account = accounts(:depository)
    visit account_path(account)
    assert_active_in_sidebar account

    page.execute_script(%(window.__morphed = false; document.addEventListener("turbo:morph", () => { window.__morphed = true }, { once: true }); Turbo.visit(location.href, { action: "replace" })))
    wait_until(timeout: 15) { page.evaluate_script("window.__morphed") }
    assert page.evaluate_script("window.__morphed"), "the refresh morphed the page"

    assert_active_in_sidebar account
  end

  test "the dashboard highlights no account" do
    visit root_path

    assert_selector "#sidebar-scroll a[data-sidebar-account-id]", visible: :all, minimum: 1
    assert_no_selector "#sidebar-scroll a[data-active-account]", visible: :all
  end

  test "on a phone the drawer highlights the open account" do
    page.driver.browser.manage.window.resize_to(390, 844)
    account = accounts(:depository)
    visit account_path(account)

    find("nav.lg\\:hidden [data-action*='app-layout#openMobileSidebar']", match: :first).click

    within "[data-app-layout-target='mobileSidebar']" do
      link = find("[role=tabpanel]:not(.hidden) a[data-sidebar-account-id='#{account.id}']")
      assert_equal "true", link["data-active-account"]
      assert link[:class].split.include?("bg-container")
      assert link.ancestor("details")[:open]
    end
  end

  private
    def assert_active_in_sidebar(account)
      link = find("#sidebar-scroll [role=tabpanel]:not(.hidden) a[data-sidebar-account-id='#{account.id}']")
      assert_equal "true", link["data-active-account"]
      assert link[:class].split.include?("bg-container"), "the open account's link is highlighted"
      assert_not link[:class].split.include?("hover:bg-surface-hover")
      assert link.ancestor("details")[:open], "the open account's group is open"
    end
end
