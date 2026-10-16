require "application_system_test_case"

class TransactionRepeatTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @account = accounts(:depository)
  end

  test "switch repeat on in the new-transaction form and get a bill paid by the entry" do
    visit new_transaction_path

    assert_no_selector "[data-repeat-fields-target='fields']", visible: true

    fill_in "entry[name]", with: "Rent"
    select_ds("Account", @account)
    fill_in "entry[amount]", with: "900"
    find("label[for='repeat_enabled']").click

    assert_selector "[data-repeat-fields-target='fields']", visible: true
    assert find("#repeat_auto_post", visible: :all).checked?

    click_button I18n.t("transactions.form.submit")

    assert_text I18n.t("transactions.create.created_repeating")
    series = @user.family.recurring_transactions.find_by!(name: "Rent")
    assert series.auto_post?
    assert_equal [ @account.entries.find_by!(name: "Rent").id ],
                 series.recurring_occurrences.find_by!(due_on: Date.current).allocations.pluck(:entry_id)
  end
end
