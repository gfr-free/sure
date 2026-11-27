require "application_system_test_case"

# The shared Enter rule (utils/search_match) for every picker: Enter in the
# search box never submits the form, picks the exact name, else the first
# visible row.
class PickerEnterTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    Entry.delete_all
    @entry = create_transaction(account: accounts(:depository), name: "Coffee", amount: 4)
  end

  test "Enter in the merchant picker picks the typed name and keeps the drawer open" do
    open_bulk_edit
    within "#bulk_transaction_edit_drawer" do
      find("[data-merchant-select-target='button']").click
      find("[data-merchant-select-target='search']").fill_in(with: "NETFLIX").send_keys(:enter)

      assert_selector "[data-merchant-select-target='selectionContainer']", text: "Netflix"
      assert_equal merchants(:netflix).id, find("input[name='bulk_update[merchant_id]']", visible: :all).value
    end
    assert_equal "Coffee", @entry.reload.name
  end

  test "Enter in the tag picker adds the typed tag and keeps the drawer open" do
    open_bulk_edit
    within "#bulk_transaction_edit_drawer" do
      find("[data-tag-select-target='button']").click
      find("[data-tag-select-target='search']").fill_in(with: "trips").send_keys(:enter)

      assert_selector "[data-tag-select-target='selectionContainer']", text: "Trips"
      assert_selector "input[name='bulk_update[tag_ids][]'][value='#{tags(:one).id}']", visible: :all
    end
    assert_empty @entry.entryable.reload.tags
  end

  test "Enter in a searchable select picks the typed category" do
    open_bulk_edit
    within "#bulk_transaction_edit_drawer" do
      find("[data-select-target='button']", match: :first).click
      find("input[data-list-filter-target='input']").fill_in(with: "inco").send_keys(:enter)

      assert_equal categories(:income).id, find("input[name='bulk_update[category_id]']", visible: :all).value
    end
    assert_nil @entry.entryable.reload.category
  end

  test "Enter on the blank option of a select picks it" do
    outflow = create_transaction(account: accounts(:depository), amount: 50, category: categories(:income))
    inflow = create_transaction(account: accounts(:loan), amount: -50)
    transfer = Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable)
    visit transfer_url(transfer)

    find("summary", text: /#{I18n.t("transfers.show.details")}/i).click
    field = find("label", exact_text: I18n.t("transfers.show.category")).ancestor("div.relative")
    hidden = field.find("input[name='transfer[category_id]']", visible: :all)
    assert_equal categories(:income).id, hidden.value
    field.find("[data-select-target='button']").click
    blank = field.find("[role='option'][data-value='']")
    execute_script("arguments[0].focus()", blank)
    page.driver.browser.action.send_keys(:enter).perform

    assert_equal "", hidden.value
  end

  test "Enter in a search with several matches picks the first and submits nothing" do
    open_bulk_edit
    within "#bulk_transaction_edit_drawer" do
      find("[data-select-target='button']", match: :first).click
      search = find("input[data-list-filter-target='input']")
      # "Food & Drink" and "Income" both match.
      search.fill_in(with: "o")
      first_value = first("[data-select-target='content'] [role='option']")["data-value"]
      search.send_keys(:enter)

      assert_equal first_value, find("input[name='bulk_update[category_id]']", visible: :all).value
      assert_selector "input[name='bulk_update[name]']"
    end
    assert_nil @entry.entryable.reload.category
  end

  test "Enter in the merchant merge search checks the match instead of merging" do
    visit merge_family_merchants_path
    find("input[data-list-filter-target='input']").fill_in(with: "amaz").send_keys(:enter)

    assert find("label.filterable-item", text: "Amazon").find("input[type='checkbox']").checked?
    assert_current_path merge_family_merchants_path
  end

  test "Enter in the row tag menu adds a tag but never removes an applied one" do
    @entry.entryable.update!(tags: [ tags(:one) ])
    visit transactions_url
    find("##{dom_id(@entry.entryable, "tag_summary_desktop")}").click

    search = find("turbo-frame#tag_dropdown input[data-list-filter-target='input']")
    search.fill_in(with: "trips").send_keys(:enter)
    search.fill_in(with: "emergency fund").send_keys(:enter)

    option_id = "#{dom_id(@entry, :tag_option)}_#{tags(:two).id}"
    assert_selector "##{option_id}[aria-selected='true']"
    assert_equal [ tags(:one).id, tags(:two).id ].sort, @entry.entryable.reload.tag_ids.sort
  end

  test "a row the server redraws while another search is typed stays filtered out" do
    @entry.entryable.update!(tags: [])
    visit transactions_url
    find("##{dom_id(@entry.entryable, "tag_summary_desktop")}").click

    search = find("turbo-frame#tag_dropdown input[data-list-filter-target='input']")
    search.fill_in(with: "emergency")
    trips_id = "#{dom_id(@entry, :tag_option)}_#{tags(:one).id}"
    assert_no_selector "##{trips_id}"

    # Stands in for a late Turbo stream that redraws the Trips row.
    execute_script(<<~JS, trips_id)
      const row = document.getElementById(arguments[0]);
      const copy = row.cloneNode(true);
      copy.style.display = "";
      row.replaceWith(copy);
    JS

    assert_no_selector "##{trips_id}"
    search.send_keys(:enter)
    assert_selector "##{dom_id(@entry, :tag_option)}_#{tags(:two).id}[aria-selected='true']"
    assert_equal [ tags(:two).id ], @entry.entryable.reload.tag_ids
  end

  private
    def open_bulk_edit
      visit transactions_url
      find("##{dom_id(@entry, "selection")}").check
      within("#entry-selection-bar") { find("a[title='Edit']").click }
      assert_selector "#bulk_transaction_edit_drawer input[name='bulk_update[name]']"
    end
end
