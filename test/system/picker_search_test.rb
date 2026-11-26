require "application_system_test_case"

class PickerSearchTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    Entry.delete_all
    @family = @user.family
    @account = accounts(:depository)
  end

  test "bulk edit leaves tags alone when the tag picker is not touched" do
    entry = create_transaction(account: @account, name: "Tagged", amount: 10, tags: [ tags(:one) ])

    open_bulk_edit(entry)
    within "#bulk_transaction_edit_drawer" do
      fill_in "bulk_update[name]", with: "Renamed"
      click_button I18n.t("transactions.bulk_updates.new.save")
    end

    assert_equal "Renamed", wait_for { entry.reload.name == "Renamed" && entry.name }
    assert_equal [ tags(:one) ], entry.entryable.reload.tags.to_a
  end

  test "bulk edit sets a tag found by any word of its name" do
    entry = create_transaction(account: @account, name: "Untagged", amount: 10)

    open_bulk_edit(entry)
    within "#bulk_transaction_edit_drawer" do
      find("[data-tag-select-target='button']").click
      find("[data-tag-select-target='search']").fill_in with: "fund emergency"
      assert_selector "[data-tag-select-target='option']", text: "Emergency fund", count: 1
      assert_no_selector "[data-tag-select-target='option']", text: "Trips"
      find("[data-tag-select-target='option']", text: "Emergency fund").click
      find("[data-tag-select-target='search']").send_keys(:escape)
      click_button I18n.t("transactions.bulk_updates.new.save")
    end

    assert_equal [ tags(:two) ], wait_for { entry.entryable.reload.tags.to_a.presence }
  end

  test "the merchant picker ignores accents and offers no duplicate merchant" do
    @family.merchants.create!(name: "Café Müller", type: "FamilyMerchant")
    entry = create_transaction(account: @account, name: "Coffee", amount: 4)

    open_bulk_edit(entry)
    within "#bulk_transaction_edit_drawer" do
      find("[data-merchant-select-target='button']").click
      search = find("[data-merchant-select-target='search']")

      search.fill_in with: "muller cafe"
      assert_selector "[data-merchant-select-target='option']:not(.hidden)", text: "Café Müller", count: 1
      assert_no_selector "[data-merchant-select-target='option']:not(.hidden)", text: "Netflix"

      search.fill_in with: "café müller"
      assert_selector "[data-merchant-select-target='createForm'].hidden", visible: :all

      search.fill_in with: "Café Neu"
      assert_selector "[data-merchant-select-target='createForm']", visible: true
    end
  end

  private
    def open_bulk_edit(entry)
      visit transactions_url
      find("##{dom_id(entry, "selection")}").check
      within "#entry-selection-bar" do
        find("a[title='Edit']").click
      end
      assert_selector "#bulk_transaction_edit_drawer input[name='bulk_update[name]']"
    end

    def wait_for(timeout: Capybara.default_max_wait_time)
      deadline = Time.current + timeout
      loop do
        result = yield
        return result if result || Time.current > deadline

        sleep 0.1
      end
    end
end
