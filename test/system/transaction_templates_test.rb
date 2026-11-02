require "application_system_test_case"

class TransactionTemplatesTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "picking a template fills the New transaction form" do
    @user.family.transaction_templates.create!(
      name: "Rent", nature: "outflow", amount: 950, currency: "USD",
      account: accounts(:depository), category: categories(:food_and_drink)
    )

    visit transactions_path
    click_on "New transaction"

    within "#modal" do
      click_on "Use template"
      click_on "Rent"

      assert_field "entry[name]", with: "Rent"
      assert_field "entry[amount]", with: "950.00"
    end
  end

  test "saving a new transaction as a template" do
    visit transactions_path
    click_on "New transaction"

    within "#modal" do
      fill_in "entry[name]", with: "Gym membership"
      select_ds("Account", accounts(:depository))
      fill_in "entry[amount]", with: "30"
      find("label[for='save_as_template']", match: :first).click
      click_on "Add transaction"
    end

    assert_text "Transaction created and saved as a template"
    assert @user.family.transaction_templates.exists?(name: "Gym membership")
  end
end
