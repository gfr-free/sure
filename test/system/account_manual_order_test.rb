require "application_system_test_case"

class AccountManualOrderTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(default_account_order: "manual")
    sign_in @user
  end

  test "moving an account with the keyboard saves the new order" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    within_testid("account-sidebar-tabs") do
      assert_equal [ checking.id, plaid.id ], visible_depository_ids.first(2)
      assert_no_selector "[data-account-sortable-target='item'] [role=button]", visible: true

      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-account-sortable-target='item'][data-account-id='#{plaid.id}'] [role=button]")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)

      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
    end

    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ plaid.id, checking.id ] }

    within_testid("account-sidebar-tabs") do
      click_button I18n.t("accounts.sidebar.sort_mode.done")
      assert_no_selector "[data-account-sortable-target='item'] [role=button]", visible: true
    end

    visit account_path(checking)
    within_testid("account-sidebar-tabs") do
      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
    end
  end

  test "leaving sort mode saves a row still held with the keyboard" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-account-sortable-target='item'][data-account-id='#{plaid.id}'] [role=button]")
      handle.send_keys(:enter)
      handle.send_keys(:up)

      click_button I18n.t("accounts.sidebar.sort_mode.done")
    end

    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ plaid.id, checking.id ] }
  end

  test "a stalled save times out, shows the failure toast and lets later saves through" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    # A request that never answers, like a dropped mobile connection; it only
    # ends when the caller aborts it.
    page.execute_script(<<~JS)
      window.realFetch = window.fetch;
      window.fetch = (url, options = {}) => new Promise((resolve, reject) => {
        options.signal?.addEventListener("abort", () => reject(options.signal.reason));
      });
      document.querySelectorAll("[data-controller~='account-sortable']").forEach((list) => {
        list.setAttribute("data-account-sortable-save-timeout-value", "300");
      });
    JS

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-account-sortable-target='item'][data-account-id='#{plaid.id}'] [role=button]")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)
    end

    assert_text I18n.t("layouts.shared.notification_tray.account_order_save_failed")

    page.execute_script("window.fetch = window.realFetch")

    within_testid("account-sidebar-tabs") do
      handle = find("[data-account-sortable-target='item'][data-account-id='#{checking.id}'] [role=button]")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)
    end

    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ checking.id, plaid.id ] }
  end

  private
    def visible_depository_ids
      list = all("[data-account-sortable-group-value='depository']", visible: true).first
      list.all("[data-account-sortable-target='item']").map { |item| item["data-account-id"] }
    end

    def assert_eventually(timeout: 5)
      deadline = Time.current + timeout
      until yield
        flunk "condition not met within #{timeout}s" if Time.current > deadline
        sleep 0.1
      end
    end
end
