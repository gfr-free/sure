require "application_system_test_case"

class CategoryFilterCascadingTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    Entry.delete_all # clean slate

    @parent = categories(:food_and_drink)
    @child_one = categories(:subcategory) # "Restaurants"
    @child_two = @user.family.categories.create!(name: "Groceries", parent: @parent, color: "#4da568", lucide_icon: "shopping-bag")

    @child_one_transaction = create_transaction("restaurant purchase", 2.days.ago.to_date, 50, category: @child_one)
    @child_two_transaction = create_transaction("grocery run", 1.day.ago.to_date, 30, category: @child_two)

    visit transactions_url
  end

  # A default category stored under another locale's label shows translated;
  # its stored name still finds it.
  test "the category search finds a translated default category by its stored name" do
    @user.family.categories.create!(name: "Lebensmittel", color: "#4da568", lucide_icon: "shopping-basket")
    visit transactions_url

    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      find("[data-list-filter-target='input']").fill_in with: "Lebensmittel"

      assert_selector ".filterable-item", text: "Groceries", count: 1
    end
  end

  test "checking a parent category checks all its subcategories" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      check(@parent.name)

      assert find_field(@child_one.name).checked?
      assert find_field(@child_two.name).checked?
    end
  end

  test "unchecking one subcategory unchecks the parent and excludes only that subcategory from the filter" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      check(@parent.name)
      uncheck(@child_one.name)

      assert_not find_field(@parent.name).checked?
      assert find_field(@child_two.name).checked?

      click_button "Apply"
    end

    # Only the still-checked subcategory's transaction should show — the
    # deselected child must not sneak back in via the parent match.
    assert_selector "#" + dom_id(@child_two_transaction)
    assert_no_selector "#" + dom_id(@child_one_transaction)
  end

  test "re-checking all subcategories re-checks the parent" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      check(@parent.name)
      uncheck(@child_one.name)
      check(@child_one.name)

      assert find_field(@parent.name).checked?

      click_button "Apply"
    end

    assert_selector "#" + dom_id(@child_one_transaction)
    assert_selector "#" + dom_id(@child_two_transaction)
  end

  test "reopening a parent-only filter from the URL keeps it checked and active on Apply" do
    visit transactions_url(q: { categories: [ @parent.name ] })

    assert_selector "#" + dom_id(@child_one_transaction)
    assert_selector "#" + dom_id(@child_two_transaction)

    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"

      assert find_field(@parent.name).checked?
      assert find_field(@child_one.name).checked?
      assert find_field(@child_two.name).checked?

      click_button "Apply"
    end

    assert_selector "#" + dom_id(@child_one_transaction)
    assert_selector "#" + dom_id(@child_two_transaction)
  end

  test "searching the parent lists its subcategories, and checking it still checks them" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      find("input[type='search']", visible: true).fill_in with: "Food"

      assert_field @child_one.name
      assert_field @child_two.name
      assert_no_field categories(:income).name

      check(@parent.name)
      assert_checked_field @child_one.name
      assert_checked_field @child_two.name
    end
  end

  test "searching a subcategory lists its whole group, so checking the parent hides nothing" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      find("input[type='search']", visible: true).fill_in with: @child_two.name

      # Checking the parent checks every subcategory, so the siblings show too.
      assert_field @parent.name
      assert_field @child_one.name
      assert_field @child_two.name
      assert_no_field categories(:income).name

      check(@parent.name)
      assert_checked_field @child_one.name
      assert_checked_field @child_two.name
    end
  end

  private

    def create_transaction(name, date, amount, category:)
      accounts(:depository).entries.create! \
        name: name,
        date: date,
        amount: amount,
        currency: "USD",
        entryable: Transaction.new(category: category)
    end
end
