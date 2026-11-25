require "application_system_test_case"

# Every amount input is the shared money field: a comma decimal or a simple
# expression is read the same way as on a new transaction, and the server gets
# a plain number.
class MoneyFieldsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)
  end

  test "a transfer reads a comma decimal expression and comma fees" do
    visit new_transfer_url

    select_ds("From", accounts(:depository))
    select_ds("To", accounts(:credit_card))

    fill_in "transfer[amount]", with: "12,50+4,30"
    find("summary", text: /bank charges/i).click
    fill_in "transfer[source_fee_amount]", with: "1,25"
    fill_in "Date", with: Date.current

    click_button "Create transfer"

    assert_current_path transactions_url
    transfer = Transfer.joins(outflow_transaction: :entry).where(entries: { account_id: accounts(:depository).id }).order(created_at: :desc).first
    assert_equal 16.80.to_d, transfer.outflow_transaction.entry.amount
    assert_equal 1.25.to_d, transfer.derived_source_fee_amount
  end

  test "a transfer's amount shows the currency of the account it leaves" do
    eur_account = @user.family.accounts.create!(name: "EUR Savings", balance: 1000, currency: "EUR", accountable: Depository.new)

    visit new_transfer_url

    amount_field = find_field("transfer[amount]").ancestor("[data-controller='money-field']")
    assert_selector "[data-money-field-target='symbol']", text: "$"

    select_ds("From", eur_account)

    within(amount_field) { assert_selector "[data-money-field-target='symbol']", text: "€" }
  end

  test "split rows add up typed comma amounts" do
    entry = create_transaction(amount: 100, name: "Split me", account: accounts(:depository))

    visit new_transaction_split_path(entry)

    within "dialog" do
      find("[data-split-transaction-target='amountInput']").fill_in(with: "-60,50")
      click_on I18n.t("splits.new.add_row")
      rows = all("[data-split-transaction-target='row']", count: 2)
      within(rows.last) do
        find("[data-split-transaction-target='nameInput']").fill_in(with: "Rest")
        find("[data-split-transaction-target='amountInput']").fill_in(with: "-39,50")
      end

      assert_selector "[data-split-transaction-target='remaining']", text: "0.00"
    end
  end

  test "a rule condition switched to amount gets the money field" do
    visit new_rule_url(resource_type: "transaction")

    within "dialog" do
      click_on "Add condition"
      condition = find("[data-rules-target='conditionsList'] li[data-controller='rule--conditions']", match: :first)
      within(condition) do
        find("select[name$='[condition_type]']").find("option[value='transaction_amount']").select_option

        assert_selector "[data-controller='money-field'] input[name$='[value]']"
        find("input[name$='[value]']").fill_in(with: "12,50")
        assert_equal "", find("input[name$='[value]']")[:validationMessage].to_s
      end
    end
  end
end
