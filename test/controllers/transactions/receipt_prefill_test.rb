require "test_helper"

class Transactions::ReceiptPrefillTest < ActionDispatch::IntegrationTest
  include ReceiptPdfHelper

  setup do
    ensure_tailwind_build
    @user = users(:family_admin)
    @family = @user.family
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @account = accounts(:depository)
    @receipt = Receipt.create_from_upload!(family: @family, user: @user, file: uploaded_receipt(receipt_pdf([ "Total 6.40" ]), filename: "bakery.pdf"))
    @receipt.update!(merchant_name: "Corner Bakery", amount: 6.4, currency: "USD", date: Date.new(2026, 11, 20), extraction_status: "completed")
  end

  test "the new-transaction form offers to fill in from a receipt" do
    get new_transaction_url

    assert_response :success
    assert_select "form[action=?] input[type=file][name='receipt[file]']", prefill_receipts_path
  end

  test "the form is filled in from the receipt and warns about an existing booking" do
    @account.entries.create!(name: "CARD PAYMENT BAKERY", date: Date.new(2026, 11, 21), amount: 6.4, currency: "USD", entryable: Transaction.new)

    get new_transaction_url(receipt_id: @receipt.id)

    assert_response :success
    assert_select "input[name='entry[name]'][value=?]", "Corner Bakery"
    assert_select "input[name='entry[date]'][value=?]", "2026-11-20"
    assert_select "input[type='text'][name='entry[amount]']" do |elements|
      assert_equal "6.40", elements.first["value"]
    end
    assert_select "input[type=hidden][name=receipt_id][value=?]", @receipt.id
    assert_select "p", text: /CARD PAYMENT BAKERY/
  end

  test "another user's receipt is not used" do
    other = Receipt.create_from_upload!(family: @family, user: users(:family_member), file: uploaded_receipt(receipt_pdf([ "Total 1.00" ]), filename: "other.pdf"))
    other.update!(merchant_name: "Secret Shop")

    get new_transaction_url(receipt_id: other.id)

    assert_response :success
    assert_select "input[name=receipt_id]", count: 0
    assert_select "input[name='entry[name]'][value=?]", "Secret Shop", count: 0
  end

  test "saving the transaction links the receipt and marks it as created from the receipt" do
    assert_difference -> { @account.entries.count }, 1 do
      post transactions_url, params: { receipt_id: @receipt.id, entry: new_entry_params }
    end

    entry = @account.entries.order(:created_at).last
    @receipt.reload
    assert_equal entry.transaction, @receipt.linked_transaction
    assert @receipt.match_confirmed?
    assert @receipt.created_transaction?
    assert_equal 1, entry.transaction.attachments.count
  end

  test "the transaction is saved even when the receipt was linked meanwhile" do
    other = @account.entries.create!(name: "Elsewhere", date: Date.current, amount: 1, currency: "USD", entryable: Transaction.new)
    @receipt.link_to!(other.transaction, user: @user)

    assert_difference -> { @account.entries.count }, 1 do
      post transactions_url, params: { receipt_id: @receipt.id, entry: new_entry_params }
    end

    assert_equal other.transaction, @receipt.reload.linked_transaction
  end

  test "a receipt suggested meanwhile is linked to the new transaction instead" do
    @account.entries.create!(name: "Bank booking", date: Date.new(2026, 11, 21), amount: 6.4, currency: "USD", entryable: Transaction.new)
    assert @receipt.auto_match!

    post transactions_url, params: { receipt_id: @receipt.id, entry: new_entry_params }

    entry = @account.entries.order(:created_at).last
    assert_equal entry.transaction, @receipt.reload.linked_transaction
    assert @receipt.match_confirmed?
  end

  test "says so when the receipt could not be linked" do
    other = @account.entries.create!(name: "Elsewhere", date: Date.current, amount: 1, currency: "USD", entryable: Transaction.new)
    @receipt.link_to!(other.transaction, user: @user)

    post transactions_url, params: { receipt_id: @receipt.id, entry: new_entry_params }

    assert_equal I18n.t("transactions.create.receipt_not_linked"), flash[:alert]
  end

  test "a bank-synced account is refused while the receipt waits for the bank" do
    travel_to Date.new(2026, 11, 22) do
      assert_no_difference -> { Entry.count } do
        post transactions_url, params: { receipt_id: @receipt.id, entry: new_entry_params.merge(account_id: accounts(:connected).id) }
      end
    end

    assert_response :unprocessable_entity
    assert_nil @receipt.reload.transaction_id
  end

  test "reading a receipt keeps the account the dialog was opened with" do
    file = uploaded_receipt(receipt_pdf([ "Total 3.30" ]), filename: "kiosk.pdf")

    post prefill_receipts_url, params: { account_id: @account.id, nature: "outflow", receipt: { file: file } }

    receipt = @family.receipts.order(:created_at).last
    assert_redirected_to new_transaction_url(receipt_id: receipt.id, account_id: @account.id, nature: "outflow")
  end

  test "a failed save keeps the receipt in the form" do
    post transactions_url, params: { receipt_id: @receipt.id, entry: new_entry_params.merge(amount: "") }

    assert_response :unprocessable_entity
    assert_select "input[type=hidden][name=receipt_id][value=?]", @receipt.id
    assert_nil @receipt.reload.transaction_id
  end

  test "without preview features the receipt is ignored" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    post transactions_url, params: { receipt_id: @receipt.id, entry: new_entry_params }

    assert_nil @receipt.reload.transaction_id
  end

  private
    def new_entry_params
      {
        account_id: @account.id,
        name: "Corner Bakery",
        date: "2026-11-20",
        currency: "USD",
        amount: "6.40",
        nature: "outflow",
        entryable_type: "Transaction",
        entryable_attributes: { category_id: "" }
      }
    end
end
