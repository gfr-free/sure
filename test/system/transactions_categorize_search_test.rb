require "application_system_test_case"

class TransactionsCategorizeSearchTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    Entry.delete_all
    @entry = create_transaction(account: accounts(:depository), name: "Categorize search", amount: 25)
  end

  test "Enter after a subcategory search assigns the subcategory, not the parent shown above it" do
    subcategory = categories(:subcategory)
    visit transactions_categorize_url

    filter = find("[data-categorize-target='filter']")
    filter.fill_in with: "Restaur"

    within "[data-categorize-target='list']" do
      assert_selector ".filterable-item", text: categories(:food_and_drink).name
      assert_selector ".filterable-item", text: subcategory.name
    end

    filter.send_keys(:enter)

    assert_no_selector "[data-categorize-target='filter']"
    assert_equal subcategory.id, @entry.entryable.reload.category_id
  end
end
