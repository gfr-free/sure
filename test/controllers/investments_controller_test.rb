require "test_helper"

class InvestmentsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
  end

  test "update writes loss pot balances and the joint account split" do
    @account.share_with!(users(:family_member))

    patch investment_path(@account), params: {
      account: {
        loss_pot_stocks_amount: "1200.50", loss_pot_general_amount: "", loss_pot_as_of: "2025-12-31",
        loss_pot_carry_forward: "0", tax_joint_user_id: users(:family_member).id, tax_owner_share: "60"
      }
    }

    @account.reload
    stocks = @account.loss_pots.sole
    assert_equal "stocks", stocks.kind
    assert_not stocks.carry_forward?
    assert_equal [ [ Date.new(2025, 12, 31), BigDecimal("1200.5") ] ], stocks.snapshots.map { |s| [ s.date, s.amount ] }
    assert_equal users(:family_member), @account.tax_joint_user
    assert_equal BigDecimal("60"), @account.tax_owner_share

    # A new statement adds a balance; the old one stays as history.
    patch investment_path(@account), params: { account: { loss_pot_stocks_amount: "900", loss_pot_as_of: "2026-03-31" } }

    assert_equal [ BigDecimal("1200.5"), BigDecimal("900") ], @account.loss_pots.sole.snapshots.map(&:amount)
  end

  test "update rejects a joint person the account is not shared with and negative pots" do
    patch investment_path(@account), params: { account: { tax_joint_user_id: users(:empty).id } }
    assert_response :unprocessable_entity
    patch investment_path(@account), params: { account: { tax_joint_user_id: users(:family_member).id } }
    assert_response :unprocessable_entity
    assert_nil @account.reload.tax_joint_user_id

    patch investment_path(@account), params: { account: { loss_pot_general_amount: "-5" } }
    assert_response :unprocessable_entity
    assert_empty @account.reload.loss_pots
  end

  test "the loss pot fields are preview only" do
    @account.share_with!(users(:family_member))
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    get edit_account_url(@account)
    assert_select "[data-testid='account-loss-pot-fields']", 0

    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    get edit_account_url(@account)
    assert_select "input[name='account[loss_pot_stocks_amount]']", 1
    assert_select "input[name='account[loss_pot_general_amount]']", 1
    assert_select "select[name='account[tax_joint_user_id]'] option[value='#{users(:family_member).id}']", 1
  end

  test "unsharing the account ends the joint split" do
    @account.share_with!(users(:family_member))
    @account.update!(tax_joint_user: users(:family_member))

    @account.unshare_with!(users(:family_member))

    assert_nil @account.reload.tax_joint_user_id
  end
end
