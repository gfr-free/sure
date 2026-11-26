require "application_system_test_case"

class TransactionsBulkCategorySearchTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    Entry.delete_all
    @entry = create_transaction(account: accounts(:depository), name: "Bulk category search", amount: 10)

    visit transactions_url
    find("##{dom_id(@entry, "selection")}").check
    within("#entry-selection-bar") { find("a[title='Edit']").click }
  end

  test "searching a subcategory lists its parent, and ArrowDown starts at the subcategory" do
    subcategory = categories(:subcategory)

    within "#bulk_transaction_edit_drawer" do
      category_select = find("input[name='bulk_update[category_id]']", visible: :all)
        .find(:xpath, "ancestor::div[@data-controller][contains(@data-controller, 'select')][1]")
      category_select.find("button[data-select-target='button']").click

      within category_select do
        search = find("input[type='search']")
        search.fill_in with: "Restaur"

        assert_selector "[role='option']", text: categories(:food_and_drink).name
        assert_selector "[role='option']", text: subcategory.name
        assert_no_selector "[role='option']", text: categories(:income).name

        search.send_keys(:down, :enter)
      end

      assert_selector "input[name='bulk_update[category_id]'][value='#{subcategory.id}']", visible: :all
    end
  end
end
