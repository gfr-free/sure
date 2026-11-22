require "test_helper"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest
  include ReceiptPdfHelper

  setup do
    ensure_tailwind_build
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = @admin.family
    enable_preview!(@admin)
    enable_preview!(@member)
    sign_in @admin
    @account = accounts(:depository)
  end

  test "requires preview features" do
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))

    get receipts_url

    assert_redirected_to root_url
  end

  test "lists only the signed-in user's receipts" do
    own = upload_for(@admin, "own.pdf")
    other = upload_for(@member, "other.pdf")

    get receipts_url

    assert_response :success
    assert_select "a", text: own.filename
    assert_select "a", text: other.filename, count: 0
  end

  test "uploads several files and reports duplicates" do
    first = uploaded_receipt(receipt_pdf([ "Total 1.00" ]), filename: "a.pdf")
    second = uploaded_receipt(receipt_pdf([ "Total 2.00" ]), filename: "b.pdf")

    assert_difference -> { @family.receipts.count }, 2 do
      post receipts_url, params: { receipt: { files: [ first, second ] } }
    end
    assert_redirected_to receipts_url
    assert_equal I18n.t("receipts.create.uploaded", count: 2), flash[:notice]

    assert_no_difference -> { @family.receipts.count } do
      post receipts_url, params: { receipt: { files: [ uploaded_receipt(receipt_pdf([ "Total 1.00" ]), filename: "again.pdf") ] } }
    end
    assert_equal I18n.t("receipts.create.duplicates", count: 1), flash[:alert]
  end

  test "uploads an e-invoice and shows its invoice details" do
    xml = uploaded_receipt(file_fixture("e_invoices/cii_invoice.xml").read, filename: "invoice.xml", content_type: "application/xml")

    assert_difference -> { @family.receipts.count }, 1 do
      post receipts_url, params: { receipt: { files: [ xml ] } }
    end
    receipt = @family.receipts.order(:created_at).last
    receipt.extract!

    get receipt_url(receipt)

    assert_response :success
    assert_select "dd", text: "DEMO-2026-0042"
    assert_not_includes response.body, I18n.t("receipts.show.open_pdf")
    assert_not_includes response.body, I18n.t("receipts.show.nothing_read")
  end

  test "another user's receipt is not found" do
    other = upload_for(@member, "other.pdf")

    get receipt_url(other)
    assert_response :not_found

    get file_receipt_url(other)
    assert_response :not_found
  end

  test "shows a receipt and its matching transactions" do
    receipt = upload_for(@admin, "lunch.pdf")
    receipt.update!(amount: 18.5, currency: "USD", date: Date.current)
    entry = @account.entries.create!(name: "Lunch spot", date: Date.current, amount: 18.5, currency: "USD", entryable: Transaction.new)

    get receipt_url(receipt)

    assert_response :success
    assert_select "p", text: entry.name
  end

  test "saves corrected fields as manual" do
    receipt = upload_for(@admin, "fix.pdf")

    patch receipt_url(receipt), params: { receipt: { merchant_name: "Corner Shop", amount: "7.25", currency: "usd", date: "2026-11-01" } }

    assert_redirected_to receipt_url(receipt)
    receipt.reload
    assert_equal "Corner Shop", receipt.merchant_name
    assert_equal BigDecimal("7.25"), receipt.amount
    assert_equal "USD", receipt.currency
    assert_equal "manual", receipt.field_source(:amount)
  end

  test "links a receipt to a transaction" do
    receipt = upload_for(@admin, "link.pdf")
    entry = @account.entries.create!(name: "Shop", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)

    post link_receipt_url(receipt), params: { transaction_id: entry.transaction.id }

    assert_redirected_to receipt_url(receipt)
    assert_equal entry.transaction, receipt.reload.linked_transaction
    assert_equal 1, entry.transaction.attachments.count
  end

  test "cannot link to a transaction on a read-only account" do
    sign_in @member
    receipt = upload_for(@member, "member.pdf")
    entry = accounts(:credit_card).entries.create!(name: "Card", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)

    post link_receipt_url(receipt), params: { transaction_id: entry.transaction.id }

    assert_response :not_found
    assert_nil receipt.reload.transaction_id
  end

  test "records a receipt as a new transaction" do
    receipt = upload_for(@admin, "new.pdf")

    assert_difference -> { @account.entries.count }, 1 do
      post create_transaction_receipt_url(receipt), params: {
        account_id: @account.id,
        transaction: { name: "Bakery", date: Date.current.iso8601, amount: "3.80", currency: "USD" }
      }
    end

    assert_redirected_to receipt_url(receipt)
    assert receipt.reload.created_transaction?
    assert_equal BigDecimal("3.80"), receipt.linked_transaction.entry.amount
  end

  test "rejects a new transaction without a valid amount" do
    receipt = upload_for(@admin, "bad.pdf")

    assert_no_difference -> { @account.entries.count } do
      post create_transaction_receipt_url(receipt), params: { account_id: @account.id, transaction: { date: Date.current.iso8601, amount: "abc" } }
    end

    assert_redirected_to receipt_url(receipt)
    assert flash[:alert].present?
  end

  test "dismisses, reopens and deletes a receipt" do
    receipt = upload_for(@admin, "gone.pdf")

    patch dismiss_receipt_url(receipt)
    assert receipt.reload.dismissed_at?

    patch reopen_receipt_url(receipt)
    assert_not receipt.reload.dismissed_at?

    assert_difference -> { @family.receipts.count }, -1 do
      delete receipt_url(receipt)
    end
    assert_redirected_to receipts_url
  end

  test "guests cannot use receipts" do
    guest = users(:family_member)
    guest.update!(role: "guest")
    sign_in guest

    get receipts_url

    assert_redirected_to root_url
  end

  private
    def enable_preview!(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def upload_for(user, filename)
      Receipt.create_from_upload!(family: user.family, user: user, file: uploaded_receipt(receipt_pdf([ "Total 1.00", filename ]), filename: filename))
    end
end
