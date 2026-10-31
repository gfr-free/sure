require "application_system_test_case"

class TagDropdownSearchTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    @entry = entries(:transaction)
  end

  test "the tag picker search field filters the tag list" do
    visit tag_dropdown_path(entry_id: @entry.id)

    search = find("input[type=search][role=combobox]:focus")

    search.set("emerg")

    assert_selector ".filterable-item", text: "Emergency fund"
    assert_no_selector ".filterable-item", text: "Trips"
    assert_no_selector ".filterable-item", text: "Test"
  end
end
