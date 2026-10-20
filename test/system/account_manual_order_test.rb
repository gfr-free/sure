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
      assert_no_selector "[data-sortable-list-target='item'] [role=button]", visible: true

      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] [role=button]")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)

      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
    end

    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ plaid.id, checking.id ] }

    within_testid("account-sidebar-tabs") do
      click_button I18n.t("accounts.sidebar.sort_mode.done")
      assert_no_selector "[data-sortable-list-target='item'] [role=button]", visible: true
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

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] [role=button]")
      handle.send_keys(:enter)
      handle.send_keys(:up)

      click_button I18n.t("accounts.sidebar.sort_mode.done")
    end

    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ plaid.id, checking.id ] }
  end

  test "a stalled save times out and reloads the saved order" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    # Order saves never answer, like a dropped mobile connection; they only
    # end when the caller aborts them. Page loads still go through.
    page.execute_script(<<~JS)
      window.realFetch = window.fetch;
      window.fetch = (url, options = {}) => {
        if (!String(url).includes("/accounts/reorder")) return window.realFetch(url, options);
        return new Promise((resolve, reject) => {
          options.signal?.addEventListener("abort", () => reject(options.signal.reason));
        });
      };
      document.querySelectorAll("[data-controller~='sortable-list']").forEach((list) => {
        list.setAttribute("data-sortable-list-save-timeout-value", "300");
      });
    JS

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] [role=button]")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)

      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
      # The failed save reloads the page, which shows the order actually saved.
      assert_eventually { visible_depository_ids.first(2) == [ checking.id, plaid.id ] }
    end

    assert_nil @user.reload.manual_account_order["depository"]
  end

  test "a move is mirrored in the other sidebar tabs" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] [role=button]")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)
    end

    lists = all("[data-sortable-list-url-value='#{reorder_accounts_path(group: "depository")}']", visible: :all)
    assert_operator lists.size, :>, 1
    lists.each do |list|
      ids = list.all("[data-sortable-list-target='item']", visible: :all).map { |item| item["data-sortable-list-id"] }
      assert_equal [ plaid.id, checking.id ], ids.first(2)
    end
  end

  private
    def visible_depository_ids
      list = all("[data-sortable-list-url-value='#{reorder_accounts_path(group: "depository")}']", visible: true).first
      list.all("[data-sortable-list-target='item']").map { |item| item["data-sortable-list-id"] }
    end

    def assert_eventually(timeout: 5)
      deadline = Time.current + timeout
      until yield
        flunk "condition not met within #{timeout}s" if Time.current > deadline
        sleep 0.1
      end
    end
end
