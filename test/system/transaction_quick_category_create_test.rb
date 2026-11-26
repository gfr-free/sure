require "application_system_test_case"

class TransactionQuickCategoryCreateTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = @user.family.entries.transactions.order(date: :desc).first
    page.current_window.resize_to(1280, 900)
  end

  test "creates a new category from the list's quick picker and assigns it" do
    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    assert_difference "Category.count", +1 do
      within "turbo-frame#category_dropdown" do
        find("input[type='search']").fill_in with: "Quick Picker Category"
        click_button 'Create "Quick Picker Category"'
      end

      # The update response re-renders the row's category menu with the new category.
      assert_selector "##{dom_id(@entry.entryable, 'category_menu_desktop')} [data-testid='category-name']", text: "Quick Picker Category"
    end

    category = @user.family.categories.find_by!(name: "Quick Picker Category")
    assert_equal category.id, @entry.entryable.reload.category_id
  end

  # Same Enter rule as the category select: while the create row shows,
  # Enter creates, even when the words also find an existing row.
  test "Enter creates while the create row shows, even next to a found row" do
    @user.family.categories.create!(name: "Pet Supplies", color: "#123456", lucide_icon: "dog")

    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    assert_difference "Category.count", +1 do
      within "turbo-frame#category_dropdown" do
        find("input[type='search']").fill_in with: "supplies pet"
        assert_selector ".filterable-item", text: "Pet Supplies"
        assert_button 'Create "supplies pet"'
        find("input[type='search']").send_keys(:enter)
      end

      assert_selector "##{dom_id(@entry.entryable, 'category_menu_desktop')} [data-testid='category-name']", text: "supplies pet"
    end
  end

  test "hides the create option when the search exactly matches an existing category" do
    existing = @user.family.categories.alphabetically.first

    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: existing.name.upcase
      assert_no_button "Create \"#{existing.name.upcase}\""
    end
  end

  # A default category shows under its name in the viewer's locale, which can
  # differ from the stored one; creating it under the shown name would leave
  # two categories that look the same.
  test "hides the create option for a default category's translated name" do
    @user.update!(locale: "de")

    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: "Restaurants & Bars"
      assert_selector ".filterable-item", text: "Restaurants & Bars"
      assert_no_selector "[data-category-quick-create-target='createButton']"

      # The stored name finds it too, instead of "no categories found".
      find("input[type='search']").fill_in with: "Food & Drink"
      assert_selector ".filterable-item", text: "Restaurants & Bars"
    end
  end

  test "creates a new subcategory from the list's quick picker and assigns it" do
    parent = categories(:food_and_drink)
    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    assert_difference "Category.count", +1 do
      within "turbo-frame#category_dropdown" do
        find("input[type='search']").fill_in with: "Quick Picker Subcategory"
        click_button "Add as a subcategory…"
        assert_text 'Create "Quick Picker Subcategory" under:'
        find("button[data-parent-id='#{parent.id}']").click
      end

      assert_selector "##{dom_id(@entry.entryable, 'category_menu_desktop')} [data-testid='category-name']", text: "Quick Picker Subcategory"
    end

    category = @user.family.categories.find_by!(name: "Quick Picker Subcategory")
    assert_equal parent, category.parent
    assert_equal category.id, @entry.entryable.reload.category_id
  end

  test "back from the quick picker's parent list returns to the category list" do
    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: "Changed My Mind"
      click_button "Add as a subcategory…"
      assert_selector "[data-category-quick-create-target='parentPicker']", visible: true

      click_button "Back"
      assert_no_selector "[data-category-quick-create-target='parentPicker']", visible: true
      assert_button 'Create "Changed My Mind"'
    end
  end

  test "hides 'No categories found' while the create option is showing" do
    visit transactions_url
    open_quick_picker

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: "Nothing Matches This"
      assert_button 'Create "Nothing Matches This"'
      assert_no_text "No categories found"
    end
  end

  test "reports a failed assignment after the category was created" do
    visit transactions_url
    open_quick_picker
    assert_selector "turbo-frame#category_dropdown input[type='search']"

    # Let the create request through but block the assign request in the
    # browser, so it fails at the network level with no response to act on.
    browser = page.driver.browser
    browser.execute_cdp("Network.enable")
    browser.execute_cdp("Network.setBlockedURLs", urls: [ "*/transactions/*/category*" ])

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: "Created But Not Assigned"
      click_button 'Create "Created But Not Assigned"'
      assert_selector "[data-category-quick-create-target='error']", text: "couldn't assign it"
    end

    assert @user.family.categories.exists?(name: "Created But Not Assigned")
    assert_not_equal "Created But Not Assigned", @entry.entryable.reload.category&.name

    # Retrying assigns the category created the first time instead of
    # posting a duplicate.
    browser.execute_cdp("Network.setBlockedURLs", urls: [])
    within "turbo-frame#category_dropdown" do
      click_button 'Create "Created But Not Assigned"'
    end

    assert_selector "##{dom_id(@entry.entryable, 'category_menu_desktop')} [data-testid='category-name']", text: "Created But Not Assigned"
    assert_equal 1, @user.family.categories.where(name: "Created But Not Assigned").count
    assert_equal "Created But Not Assigned", @entry.entryable.reload.category&.name
  ensure
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
  end

  test "choosing a parent after a failed assignment does not reuse the top-level category" do
    parent = categories(:food_and_drink)
    visit transactions_url
    open_quick_picker
    assert_selector "turbo-frame#category_dropdown input[type='search']"

    browser = page.driver.browser
    browser.execute_cdp("Network.enable")
    browser.execute_cdp("Network.setBlockedURLs", urls: [ "*/transactions/*/category*" ])

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: "Top Level First"
      click_button 'Create "Top Level First"'
      assert_selector "[data-category-quick-create-target='error']", text: "couldn't assign it"
    end

    # A different choice for the same name is a new create, which the server
    # rejects as a duplicate, instead of assigning the top-level category.
    browser.execute_cdp("Network.setBlockedURLs", urls: [])
    within "turbo-frame#category_dropdown" do
      click_button "Add as a subcategory…"
      find("button[data-parent-id='#{parent.id}']").click
      assert_selector "[data-category-quick-create-target='error']", text: /taken/i
    end

    assert_equal 1, @user.family.categories.where(name: "Top Level First").count
    assert_nil @user.family.categories.find_by(name: "Top Level First").parent
    assert_not_equal "Top Level First", @entry.entryable.reload.category&.name
  ensure
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
  end

  test "searching a category in the quick picker also lists its subcategories" do
    visit transactions_url
    open_quick_picker

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: "Food"

      assert_selector "[role='option']", text: categories(:subcategory).name
      assert_no_selector "[role='option']", text: categories(:income).name
    end
  end

  test "arrow keys in the quick picker start at the subcategory found, not at its parent" do
    subcategory = categories(:subcategory)
    visit transactions_url
    open_quick_picker

    within "turbo-frame#category_dropdown" do
      search = find("input[type='search']")
      search.fill_in with: "Restaur"
      assert_selector "[role='option']", text: categories(:food_and_drink).name

      search.send_keys(:down, :enter)
    end

    # Wait for the picker to close, so the badge checked is the row's, not one inside the open menu.
    assert_no_selector "turbo-frame#category_dropdown [role='option']"
    assert_selector "##{dom_id(@entry.entryable, 'category_menu_desktop')} [data-testid='category-name']", text: subcategory.name
    assert_equal subcategory.id, @entry.entryable.reload.category_id
  end

  test "arrow keys in the quick picker skip the Recent section hidden while searching" do
    recent = categories(:subcategory)
    recent.update!(last_used_at: 1.day.ago)
    visit transactions_url
    open_quick_picker

    within "turbo-frame#category_dropdown" do
      assert_selector "##{dom_id(recent, 'recent_category_option')}"

      search = find("input[type='search']")
      search.fill_in with: "Restaur"
      assert_no_selector "[data-list-filter-target='recentSection']"

      search.send_keys(:down)
      assert_selector "input[type='search'][aria-activedescendant='#{dom_id(recent, 'category_option')}']"
    end
  end

  private
    def open_quick_picker
      within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
        find("button", match: :first).click
      end
    end
end
