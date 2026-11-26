require "application_system_test_case"

class TransfersTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    visit transactions_url
  end

  test "can create a transfer" do
    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    # Select accounts using DS::Select
    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:credit_card))

    fill_in "transfer[amount]", with: 500
    fill_in "Date", with: transfer_date

    click_button "Create transfer"

    within "#entry-group-#{transfer_date}" do
      assert_text "Payment to"
    end
  end

  test "enter in an account search picks the match instead of submitting the form" do
    open_transfer_form
    select_ds("From", accounts(:depository))
    fill_in "transfer[amount]", with: 500
    fill_in "Date", with: Date.current

    search = open_to_search

    assert_no_difference "Transfer.count" do
      search.set(accounts(:credit_card).name)
      search.send_keys(:enter)

      assert_to_account accounts(:credit_card).id
      assert_text "New transfer"
    end
  end

  test "enter in an account search prefers the folded name over the first visible match" do
    folded = @user.family.accounts.create!(name: "Zéd", balance: 0, currency: "USD", accountable: Depository.new)
    @user.family.accounts.create!(name: "Zed Extra", balance: 0, currency: "USD", accountable: Depository.new)

    open_transfer_form
    search = open_to_search
    move_to_account_option_last(folded)

    search.set("zed")
    search.send_keys(:enter)

    assert_to_account folded.id
  end

  test "enter in an account search prefers the exact name over a folded one" do
    @user.family.accounts.create!(name: "Café", balance: 0, currency: "USD", accountable: Depository.new)
    exact = @user.family.accounts.create!(name: "Cafe", balance: 0, currency: "USD", accountable: Depository.new)

    open_transfer_form
    search = open_to_search
    move_to_account_option_last(exact)

    search.set("cafe")
    search.send_keys(:enter)

    assert_to_account exact.id
  end

  test "enter in an account search skips rows shown only for context" do
    open_transfer_form
    search = open_to_search
    search.set(accounts(:credit_card).name)

    # Mark the only hit as a context row (as a category search does for a
    # parent shown above its matching subcategory): Enter must not pick it.
    option = to_select.find("[role='option'][data-value='#{accounts(:credit_card).id}']", visible: true)
    page.execute_script("arguments[0].setAttribute('data-filter-context', '')", option)

    assert_no_difference "Transfer.count" do
      search.send_keys(:enter)
      assert_text "New transfer"
    end
    assert_no_selector "input[name='transfer[to_account_id]'][value]:not([value=''])", visible: :all
  end

  test "shows exchange rate field for different currencies" do
    # Create an account with a different currency
    eur_account = @user.family.accounts.create!(
      name: "EUR Savings",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    # Set up exchange rate
    ExchangeRate.create!(
      from_currency: "USD",
      to_currency: "EUR",
      date: Date.current,
      rate: 0.92
    )

    transfer_date = Date.current

    click_on "New transaction"
    click_on "Transfer"
    assert_text "New transfer"

    # Initially, exchange rate field should be hidden
    assert_selector "[data-transfer-form-target='exchangeRateContainer'].hidden", visible: :all

    # Select accounts with different currencies
    select_ds("From", accounts(:depository))
    select_ds("To", eur_account)

    # Exchange rate container should become visible
    assert_selector "[data-transfer-form-target='exchangeRateContainer']", visible: true

    # Exchange rate field should be populated with fetched rate
    exchange_rate_field = find("[data-transfer-form-target='exchangeRateField']")
    assert_not_empty exchange_rate_field.value
    assert_equal "0.92", exchange_rate_field.value

    # Fill in amount
    fill_in "transfer[amount]", with: 100
    fill_in "Date", with: transfer_date

    # Submit form
    click_button "Create transfer"

    # Should redirect and show transfer created
    assert_current_path transactions_url
    within "#entry-group-#{transfer_date}" do
      assert_text "Transfer to"
    end
  end

  private

    def open_transfer_form
      click_on "New transaction"
      click_on "Transfer"
      assert_text "New transfer"
    end

    # From and To render the same accounts, so every lookup stays in To.
    def to_select
      find("label", exact_text: "To").ancestor("div.relative")
    end

    def open_to_search
      to_select.find("button").click
      to_select.find("input[type='search']", visible: true)
    end

    # Put an option last so "first visible option" cannot pass by luck.
    def move_to_account_option_last(account)
      option = to_select.find("[role='option'][data-value='#{account.id}']", visible: :all)
      page.execute_script("arguments[0].parentElement.append(arguments[0])", option)
    end

    def assert_to_account(id)
      assert_selector "input[name='transfer[to_account_id]'][value='#{id}']", visible: :all
    end

    def select_ds(label_text, record)
      field_label = find("label", exact_text: label_text)
      container = field_label.ancestor("div.relative")

      # Click the button to open the dropdown
      container.find("button").click

      # If searchable, type in the search input
      if container.has_selector?("input[type='search']", visible: true)
        container.find("input[type='search']", visible: true).set(record.name)
      end

      # Wait for the listbox to appear inside the relative container
      listbox = container.find("[role='listbox']", visible: true)

      # Click the option inside the listbox
      listbox.find("[role='option'][data-value='#{record.id}']", visible: true).click
    end
end
