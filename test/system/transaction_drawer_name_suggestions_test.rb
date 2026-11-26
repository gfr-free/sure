require "application_system_test_case"

class TransactionDrawerNameSuggestionsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @account = accounts(:depository)
    # A past transaction whose name the drawer should suggest, with its usual category.
    create_transaction(account: @account, name: "Starbucks", amount: 5, category: categories(:food_and_drink))
  end

  test "picking a suggested name saves it and applies its usual category" do
    entry = create_transaction(account: @account, name: "CARD 4711", amount: 7)

    visit transaction_path(entry)
    pick_name_suggestion("Starb", "Starbucks")

    assert_category categories(:food_and_drink)
    assert_equal "Starbucks", wait_for { entry.reload.name == "Starbucks" && entry.name }
    assert_equal categories(:food_and_drink), wait_for { entry.reload.entryable.category }
  end

  test "a suggested name never replaces a category the transaction already has" do
    entry = create_transaction(account: @account, name: "CARD 4712", amount: 7, category: categories(:income))

    visit transaction_path(entry)
    pick_name_suggestion("Starb", "Starbucks")

    assert_equal "Starbucks", wait_for { entry.reload.name == "Starbucks" && entry.name }
    assert_category categories(:income)
    assert_equal categories(:income), entry.reload.entryable.category
  end

  test "a second pick does not replace or clear the category the first pick filled" do
    create_transaction(account: @account, name: "Bakery corner", amount: 3)
    entry = create_transaction(account: @account, name: "CARD 4714", amount: 7)

    visit transaction_path(entry)
    pick_name_suggestion("Starb", "Starbucks")
    assert_equal categories(:food_and_drink), wait_for { entry.reload.entryable.category }

    pick_name_suggestion("Baker", "Bakery corner")
    assert_equal "Bakery corner", wait_for { entry.reload.name == "Bakery corner" && entry.name }
    assert_category categories(:food_and_drink)
    assert_equal categories(:food_and_drink), entry.reload.entryable.category
  end

  test "a category set elsewhere while the drawer is open is kept" do
    entry = create_transaction(account: @account, name: "CARD 4715", amount: 7)

    visit transaction_path(entry)
    find("input[role='combobox'][id$='name']")
    # Stands in for an immediate rule that categorizes after the drawer rendered.
    entry.entryable.update!(category: categories(:income))
    pick_name_suggestion("Starb", "Starbucks")

    assert_equal "Starbucks", wait_for { entry.reload.name == "Starbucks" && entry.name }
    sleep 1 # give a wrongly sent category save time to land
    assert_equal categories(:income), entry.reload.entryable.category
  end

  test "a typed name without a pick is saved as typed" do
    entry = create_transaction(account: @account, name: "CARD 4713", amount: 7)

    visit transaction_path(entry)
    name_input = find("input[role='combobox'][id$='name']")
    name_input.fill_in with: "Bakery corner"
    name_input.send_keys(:escape, :tab)

    assert_equal "Bakery corner", wait_for { entry.reload.name == "Bakery corner" && entry.name }
    assert_nil entry.entryable.category
  end

  private
    def pick_name_suggestion(typed, name)
      name_input = find("input[role='combobox'][id$='name']")
      name_input.fill_in with: typed
      assert_selector ".hw-combobox [role='option']", text: name
      name_input.send_keys(:arrow_down, :enter)
      assert_field with: name
    end

    def assert_category(category)
      assert_selector("[data-category-select-target='hiddenInput']", visible: :all) { |input| input.value == category&.id.to_s }
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
