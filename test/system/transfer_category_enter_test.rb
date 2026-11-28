require "application_system_test_case"

class TransferCategoryEnterTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    @transfer = transfers(:one)
    @category = categories(:food_and_drink)
    # A payment into a loan is categorizable, so the drawer shows the
    # auto-submitting category select with its blank "Uncategorized" row.
    @transfer.inflow_transaction.entry.update!(account: accounts(:loan))
    @transfer.outflow_transaction.update!(category: @category, kind: "loan_payment")
  end

  test "enter never falls back to the blank row of an auto-submitting select" do
    visit transfer_url(@transfer)

    within("dialog[open]") do
      find("summary", text: /details/i).click
      select = find("label", exact_text: "Category").ancestor("div.relative")
      select.find("button").click
      search = select.find("input[type='search']", visible: true)

      # Only the blank "Uncategorized" row matches this partial query.
      search.set("uncategoriz")
      assert select.has_selector?("[role='option'][data-value='']", visible: true)
      search.send_keys(:enter)

      # Nothing was picked, so the menu stays open and nothing is submitted.
      assert select.has_selector?("button[aria-expanded='true']")
      assert select.has_no_selector?("[role='option'][data-value=''][aria-selected='true']", visible: :all)
    end

    assert_equal @category, @transfer.outflow_transaction.reload.category
  end
end
