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

      handle = find("[data-account-sortable-target='item'][data-account-id='#{plaid.id}'] [role=button]")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)

      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
    end

    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ plaid.id, checking.id ] }

    visit account_path(checking)
    within_testid("account-sidebar-tabs") do
      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
    end
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
