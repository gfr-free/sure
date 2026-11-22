require "test_helper"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest
  include ReceiptPdfHelper
  include ActiveJob::TestHelper

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

  test "hides the linked transaction once its account is no longer shared" do
    sign_in @member
    receipt = upload_for(@member, "shared.pdf")
    entry = @account.entries.create!(name: "Shared shop", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)
    receipt.link_to!(entry.transaction, user: @member)

    account_shares(:depository_shared_with_member).destroy!
    get receipt_url(receipt)

    assert_response :success
    assert_no_match "Shared shop", response.body
    assert_match I18n.t("receipts.show.linked_hidden"), response.body
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

  test "lists suggested receipts and confirms one" do
    receipt = suggested_receipt(@admin, "suggested.pdf")
    transaction = receipt.linked_transaction

    get receipts_url
    assert_response :success
    assert_select "h2", text: I18n.t("receipts.index.suggested_title")
    assert_select "button", text: I18n.t("receipts.suggestion.confirm")

    post confirm_match_receipt_url(receipt), headers: { "HTTP_REFERER" => receipts_url }

    assert_redirected_to receipts_url
    assert receipt.reload.match_confirmed?
    assert_equal 1, transaction.attachments.count
  end

  test "rejects a suggestion" do
    receipt = suggested_receipt(@admin, "reject.pdf")
    transaction = receipt.linked_transaction

    post reject_match_receipt_url(receipt)

    assert_redirected_to receipt_url(receipt)
    assert_nil receipt.reload.transaction_id
    assert receipt.rejected_matches.exists?(transaction_id: transaction.id)
  end

  test "the receipts list hides a suggestion once its account is no longer shared" do
    sign_in @member
    receipt = suggested_receipt(@member, "unshared.pdf")
    assert receipt.suggested?

    account_shares(:depository_shared_with_member).destroy!
    get receipts_url

    assert_response :success
    assert_no_match "Suggested shop", response.body
  end

  test "a suggestion that changed after the page was shown is neither confirmed nor rejected" do
    receipt = suggested_receipt(@admin, "stale.pdf")
    shown = receipt.transaction_id
    other = @account.entries.create!(name: "Other shop", date: Date.new(2026, 11, 6), amount: 11.11, currency: "USD", entryable: Transaction.new)
    receipt.update!(linked_transaction: other.transaction)

    post confirm_match_receipt_url(receipt, transaction_id: shown)
    assert_equal I18n.t("activerecord.errors.models.receipt.attributes.base.suggestion_changed"), flash[:alert]
    post reject_match_receipt_url(receipt, transaction_id: shown)

    assert receipt.reload.match_pending?
    assert_equal other.transaction, receipt.linked_transaction
    assert_not receipt.rejected_matches.exists?
  end

  test "cannot confirm or reject another user's suggestion" do
    receipt = suggested_receipt(@member, "member.pdf")

    post confirm_match_receipt_url(receipt)
    assert_response :not_found
    post reject_match_receipt_url(receipt)
    assert_response :not_found
    assert receipt.reload.match_pending?
  end

  test "shows the suggestion only to the uploader in the transaction drawer" do
    receipt = suggested_receipt(@admin, "drawer.pdf")
    entry = receipt.linked_transaction.entry

    get transaction_url(entry)
    assert_select "a", text: "drawer.pdf"

    sign_in @member
    get transaction_url(entry)
    assert_response :success
    assert_select "a", text: "drawer.pdf", count: 0
  end

  test "correcting the amount looks for a matching transaction" do
    receipt = upload_for(@admin, "fix-amount.pdf")
    receipt.update!(extraction_status: "completed")
    entry = @account.entries.create!(name: "Kiosk", date: Date.new(2026, 11, 3), amount: 4.2, currency: "USD", entryable: Transaction.new)

    patch receipt_url(receipt), params: { receipt: { amount: "4.20", currency: "USD", date: "2026-11-02" } }

    assert_equal entry.transaction, receipt.reload.linked_transaction
    assert receipt.match_pending?
  end

  test "while waiting for the bank only manual accounts are offered for a new transaction" do
    receipt = upload_for(@admin, "wait.pdf")
    receipt.update!(amount: 9, currency: "USD", date: Date.current, extraction_status: "completed")

    get receipt_url(receipt)

    assert_response :success
    assert_select "select[name=account_id] option", text: @account.name
    assert_select "select[name=account_id] option", text: accounts(:connected).name, count: 0
    assert_select "p", text: I18n.t("receipts.show.bank_wait_hint", date: I18n.l(receipt.bank_wait_until, format: :long))

    travel_to receipt.bank_wait_until do
      get receipt_url(receipt)
      assert_select "select[name=account_id] option", text: accounts(:connected).name
    end
  end

  test "reads a receipt from the new-transaction form and opens the form filled in" do
    file = uploaded_receipt(receipt_pdf([ "Corner Bakery", "Total 6.40 USD", "Date #{Date.current.iso8601}" ]), filename: "bakery.pdf")

    assert_no_enqueued_jobs(only: ReceiptExtractionJob) do
      assert_difference -> { @family.receipts.count }, 1 do
        post prefill_receipts_url, params: { receipt: { file: file } }
      end
    end

    receipt = @family.receipts.order(:created_at).last
    assert_redirected_to new_transaction_url(receipt_id: receipt.id)
    assert receipt.extraction_completed?
    assert_equal BigDecimal("6.40"), receipt.amount
  end

  test "the new-transaction form reports a file it cannot read" do
    post prefill_receipts_url, params: { receipt: { file: uploaded_receipt("plain", filename: "a.txt", content_type: "text/plain") } }

    assert_redirected_to new_transaction_url(receipt_error: "invalid")
  end

  test "the new-transaction form reuses an open receipt uploaded before and refuses a linked one" do
    content = receipt_pdf([ "Total 2.00" ])
    receipt = Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt(content))

    assert_no_difference -> { @family.receipts.count } do
      post prefill_receipts_url, params: { receipt: { file: uploaded_receipt(content) } }
    end
    assert_redirected_to new_transaction_url(receipt_id: receipt.id)

    receipt.dismiss!
    post prefill_receipts_url, params: { receipt: { file: uploaded_receipt(content) } }
    assert_redirected_to new_transaction_url(receipt_error: "not_open")
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

    def suggested_receipt(user, filename)
      receipt = upload_for(user, filename)
      receipt.update!(amount: 11.11, currency: "USD", date: Date.new(2026, 11, 5), extraction_status: "completed")
      @account.entries.create!(name: "Suggested shop", date: Date.new(2026, 11, 6), amount: 11.11, currency: "USD", entryable: Transaction.new)
      receipt.auto_match!
      receipt
    end

    def upload_for(user, filename)
      Receipt.create_from_upload!(family: user.family, user: user, file: uploaded_receipt(receipt_pdf([ "Total 1.00", filename ]), filename: filename))
    end
end
