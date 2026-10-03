require "application_system_test_case"

class ContractsTest < ApplicationSystemTestCase
  teardown do
    travel_back
  end

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @bill = recurring_transactions(:netflix_subscription)
  end

  test "record a contract from a bill, then end it together with the bill" do
    visit bill_url(@bill)
    click_on I18n.t("bills.contract_line.record")

    # The dialog arrives prefilled from the bill, with the bill ticked.
    assert_field "contract[name]", with: @bill.display_name
    assert_checked_field "contract_bill_#{@bill.id}"
    fill_in "contract[contract_number]", with: "NF-123456"
    click_button I18n.t("contracts.form.create")

    assert_text I18n.t("contracts.create.success")
    contract = @family.contracts.find_by!(name: @bill.display_name)
    assert_equal contract, @bill.reload.contract
    assert_text "NF-123456"

    # One step ends the contract, and the linked bill with it.
    ends_on = 3.days.from_now.to_date
    visit new_contract_ending_url(contract)
    fill_in "ending[ends_on]", with: ends_on.strftime("%m/%d/%Y")
    click_button I18n.t("contracts.endings.new.submit")

    assert_text I18n.t("contracts.endings.create.success")
    assert_text I18n.t("contracts.end_notice.ends", date: I18n.l(ends_on, format: :long))
    assert contract.reload.ended?
    assert_equal ends_on, @bill.reload.end_on
  end
end
