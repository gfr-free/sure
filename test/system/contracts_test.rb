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

  test "record a contract from a bill, cancel it, and end the bill it outlived" do
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

    # Record the cancellation; the linked bill keeps running by default.
    visit new_contract_cancellation_url(contract)
    fill_in "cancellation[ends_on]", with: 3.days.from_now.to_date.strftime("%m/%d/%Y")
    click_button I18n.t("contracts.cancellations.new.submit")

    assert_text I18n.t("contracts.cancellations.create.success")
    assert contract.reload.cancellation_sent?
    assert @bill.reload.ends_never?

    # Once the contract has ended, the bill page says the bill outlived it.
    travel_to 5.days.from_now
    visit bill_url(@bill)
    assert_text I18n.t("bills.contract_line.ended_on", date: I18n.l(contract.ends_on, format: :long))
    click_on I18n.t("bills.contract_line.end_bill")

    assert_text I18n.t("contracts.end_linked_bills.success")
    assert_equal contract.ends_on, @bill.reload.end_on
  end
end
