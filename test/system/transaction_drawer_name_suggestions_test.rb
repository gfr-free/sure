require "application_system_test_case"

class TransactionDrawerNameSuggestionsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  # Holds the server's response to drawer saves of one name until the test
  # fails or sends it, so responses can arrive in a chosen order.
  module HeldNameSaves
    mattr_accessor :held_name, :waiting, instance_accessor: false

    def self.hold(name)
      self.waiting = []
      self.held_name = name
    end

    def self.release
      self.held_name = nil
      waiting&.each { |gate| gate << :send }
    end

    def update
      return super unless HeldNameSaves.held_name && params.dig(:entry, :name) == HeldNameSaves.held_name

      gate = Thread::Queue.new
      HeldNameSaves.waiting << gate
      return super if gate.pop(timeout: 30) != :fail

      render turbo_stream: [], status: :unprocessable_entity
    end
  end
  TransactionsController.prepend(HeldNameSaves)

  teardown { HeldNameSaves.release }

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
    create_transaction(account: @account, name: "Bakery corner", amount: 3, category: categories(:income))
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
    # The drawer filled Food & Drink in on the client; the server keeps Income
    # and redraws the picker with it, which also means its request has landed.
    assert_category categories(:income)
    assert_equal categories(:income), entry.reload.entryable.category
  end

  test "the picked name typed again after another name is saved again" do
    entry = create_transaction(account: @account, name: "CARD 4716", amount: 7)

    visit transaction_path(entry)
    pick_name_suggestion("Starb", "Starbucks")
    assert_equal "Starbucks", wait_for { entry.reload.name == "Starbucks" && entry.name }

    name_input = find("input[role='combobox'][id$='name']")
    name_input.fill_in with: "Other shop"
    name_input.send_keys(:escape, :tab)
    assert_equal "Other shop", wait_for { entry.reload.name == "Other shop" && entry.name }

    name_input.fill_in with: "Starbucks"
    name_input.send_keys(:escape, :tab)
    assert_equal "Starbucks", wait_for { entry.reload.name == "Starbucks" && entry.name }
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

  test "a save of an earlier pick that fails late does not drop the same name picked again" do
    create_transaction(account: @account, name: "Plain shop", amount: 3)
    entry = create_transaction(account: @account, name: "CARD 4716", amount: 7)
    visit transaction_path(entry)
    find("input[role='combobox'][id$='name']")
    count_failed_saves
    HeldNameSaves.hold("Starbucks")

    # Request order: Starbucks (held), Plain shop, Starbucks again (held).
    pick_name_suggestion("Starb", "Starbucks")
    assert_held_name_saves 1
    pick_name_suggestion("Plain", "Plain shop")
    assert_equal "Plain shop", wait_for { entry.reload.name == "Plain shop" && entry.name }
    # Turbo cancels the save still in flight when the next one starts.
    assert_equal 1, evaluate_script("window.failedSaves")
    pick_name_suggestion("Starb", "Starbucks")
    assert_held_name_saves 2

    # The first Starbucks save fails on the server only after the second pick.
    HeldNameSaves.waiting[0] << :fail
    HeldNameSaves.waiting[1] << :send

    assert_equal "Starbucks", wait_for { entry.reload.name == "Starbucks" && entry.name }
    assert_category categories(:food_and_drink)
    assert_equal categories(:food_and_drink), wait_for { entry.reload.entryable.category }
    assert_equal 1, evaluate_script("window.failedSaves")
  end

  test "a picked name whose save another field cancels is saved again and fills its category" do
    entry = create_transaction(account: @account, name: "CARD 4717", amount: 7)
    visit transaction_path(entry)
    find("input[role='combobox'][id$='name']")
    HeldNameSaves.hold("Starbucks")

    pick_name_suggestion("Starb", "Starbucks")
    assert_held_name_saves 1
    # Saving the date while the name save is in flight makes Turbo cancel it.
    date_input = find("input[name='entry[date]']")
    date_input.set(1.day.ago.to_date)
    date_input.send_keys(:tab)
    assert_equal 1.day.ago.to_date, wait_for { entry.reload.date == 1.day.ago.to_date && entry.date }

    assert_held_name_saves 2
    HeldNameSaves.waiting.each { |gate| gate << :send }

    assert_category categories(:food_and_drink)
    assert_equal categories(:food_and_drink), wait_for { entry.reload.entryable.category }
    assert_equal "Starbucks", entry.name
  end

  test "a picked name whose save failed can be picked again" do
    entry = create_transaction(account: @account, name: "CARD 4718", amount: 7)
    visit transaction_path(entry)
    find("input[role='combobox'][id$='name']")
    count_failed_saves
    HeldNameSaves.hold("Starbucks")

    pick_name_suggestion("Starb", "Starbucks")
    assert_held_name_saves 1
    HeldNameSaves.waiting[0] << :fail
    assert_equal 1, wait_for { evaluate_script("window.failedSaves") == 1 && 1 }

    pick_name_suggestion("Starb", "Starbucks")
    assert_held_name_saves 2
    HeldNameSaves.waiting[1] << :send

    assert_category categories(:food_and_drink)
    assert_equal categories(:food_and_drink), wait_for { entry.reload.entryable.category }
  end

  private
    def count_failed_saves
      execute_script(<<~JS)
        window.failedSaves = 0;
        document.addEventListener("turbo:submit-end", (event) => { if (!event.detail.success) window.failedSaves++ });
      JS
    end

    def assert_held_name_saves(count)
      assert_equal count, wait_for { HeldNameSaves.waiting.size == count && count }
    end

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
