require "test_helper"

class ReceiptTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ReceiptPdfHelper
  include ReceiptQrHelper

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @account = accounts(:depository)
  end

  test "stores an upload and reads it in the background" do
    receipt = nil
    assert_enqueued_with(job: ReceiptExtractionJob) do
      receipt = upload([ "Coffee House", "Total 12.40 USD", "Date 2026-11-20" ])
    end

    assert receipt.extraction_pending?
    assert_equal "application/pdf", receipt.content_type
    assert_equal @family.currency, receipt.currency
    assert receipt.file.attached?
  end

  test "rejects a second upload of the same file and unsupported types" do
    content = receipt_pdf([ "Total 1.00" ])
    upload_content(content)

    assert_raises(Receipt::DuplicateUploadError) { upload_content(content) }
    assert_raises(Receipt::InvalidUploadError) do
      Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt("plain text", filename: "notes.txt", content_type: "text/plain"))
    end
  end

  test "another member may upload the same file, and long filenames are shortened" do
    content = receipt_pdf([ "Total 1.00" ])
    upload_content(content)

    receipt = Receipt.create_from_upload!(family: @family, user: @member, file: uploaded_receipt(content, filename: "#{'a' * 300}.pdf"))

    assert_equal 255, receipt.filename.length
    assert receipt.filename.end_with?(".pdf")
  end

  test "extract! keeps a field the user edited while the file was being read" do
    receipt = upload([ "Coffee House", "Total 12.40 USD" ])
    result = Receipt::Extraction::Result.new(fields: { "amount" => { value: BigDecimal("12.40"), confidence: 0.9, source: "pdf_text" } }, raw_text: "Total 12.40")
    Receipt::Extraction.any_instance.stubs(:run).with do
      Receipt.find(receipt.id).update_fields!(amount: "13.00")
      true
    end.returns(result)

    receipt.extract!

    assert_equal BigDecimal("13"), receipt.reload.amount
    assert_equal "manual", receipt.field_source(:amount)
  end

  test "update_fields! does not mark a field manual when normalizing leaves it unchanged" do
    receipt = upload([ "Total 1.00" ])

    receipt.update_fields!(currency: receipt.currency.downcase)

    assert_nil receipt.field_source(:currency)
  end

  test "extract! fills the fields from the PDF text and keeps manual edits" do
    travel_to Date.new(2026, 11, 22) do
      receipt = upload([ "Coffee House", "Total 12.40 USD", "Date 2026-11-20 08:15", "Card 4111 1111 1111 1234" ])
      receipt.update_fields!(merchant_name: "My Cafe")

      receipt.extract!

      assert receipt.extraction_completed?
      assert_equal "My Cafe", receipt.merchant_name
      assert_equal "manual", receipt.field_source(:merchant_name)
      assert_equal BigDecimal("12.40"), receipt.amount
      assert_equal "USD", receipt.currency
      assert_equal Date.new(2026, 11, 20), receipt.date
      assert_equal "pdf_text", receipt.field_source(:amount)
      assert_includes receipt.raw_text, "****1234"
      assert_not_includes receipt.raw_text, "4111"
    end
  end

  test "extract! leaves the fields of a photo without a QR code blank" do
    receipt = Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt(file_fixture("square-placeholder.png").binread, filename: "photo.png", content_type: "image/png"))

    receipt.extract!

    assert receipt.extraction_completed?
    assert_nil receipt.amount
    assert_nil receipt.raw_text
    assert_equal :open, receipt.status
  end

  test "extract! reads a till receipt's QR code on a photo" do
    travel_to Time.zone.parse("2026-11-22 12:00") do
      receipt = upload_image(receipt_qr_png(german_till_payload))

      receipt.extract!

      assert receipt.extraction_completed?
      assert_equal BigDecimal("11.59"), receipt.amount
      assert_equal Date.new(2026, 11, 20), receipt.date
      assert_equal "EUR", receipt.currency
      assert_equal "qr", receipt.field_source(:amount)
      assert_nil receipt.merchant_name
      assert_nil receipt.raw_text
      assert_equal [ "tse" ], receipt.merchant_identifiers.map { |identifier| identifier["kind"] }
    end
  end

  test "extract! takes the merchant from a PDF's text when its QR code has none" do
    travel_to Time.zone.parse("2026-11-22 12:00") do
      receipt = upload_content(receipt_qr_pdf(german_till_payload))
      Receipt::Extraction.any_instance.stubs(:pdf_text).returns("Bakery Demo\nSumme 11,59 EUR")

      receipt.extract!

      assert_equal BigDecimal("11.59"), receipt.amount
      assert_equal "qr", receipt.field_source(:amount)
      assert_equal "Bakery Demo", receipt.merchant_name
      assert_equal "pdf_text", receipt.field_source(:merchant_name)
    end
  end

  test "linking a receipt with a QR identifier teaches its merchant for the next receipt" do
    travel_to Time.zone.parse("2026-11-22 12:00") do
      merchant = merchants(:amazon)
      first = upload_image(receipt_qr_png(german_till_payload))
      first.extract!
      transaction = create_transaction(account: @account, amount: 11.59, date: Date.current)
      transaction.update!(merchant: merchant)

      first.link_to!(transaction, user: @admin)

      hint = @family.receipt_merchant_hints.sole
      assert_equal merchant, hint.merchant
      assert_equal "tse", hint.kind

      second = upload_image(receipt_qr_png(german_till_payload(gross: "2.10_0.00_0.00_0.00_0.00")))
      second.extract!

      assert_equal merchant.name, second.merchant_name
      assert_equal "qr", second.field_source(:merchant_name)
      assert_equal BigDecimal("2.10"), second.amount
    end
  end

  test "extract! still reads the PDF text when the QR reader fails" do
    receipt = upload([ "Coffee House", "Total 12.40 USD", "Date #{Date.current.iso8601}" ])
    Receipt::QrReader.stubs(:read).raises(Receipt::ExternalCommand::TimeoutError, "zbarimg timed out")

    assert_difference "DebugLogEntry.count", 1 do
      receipt.extract!
    end

    assert receipt.extraction_completed?
    assert_equal BigDecimal("12.40"), receipt.amount
    assert_equal "pdf_text", receipt.field_source(:amount)
  end

  test "a learned merchant is not offered to another family" do
    other_family = families(:empty)
    ReceiptMerchantHint.learn!(@family, [ { "kind" => "payee", "value" => "DE2051:stadtwerke demo gmbh" } ], merchants(:amazon))

    assert_nil ReceiptMerchantHint.merchant_for(other_family, [ { "kind" => "payee", "value" => "DE2051:stadtwerke demo gmbh" } ])
    assert_equal merchants(:amazon), ReceiptMerchantHint.merchant_for(@family, [ { "kind" => "payee", "value" => "DE2051:stadtwerke demo gmbh" } ])
  end

  test "extract! marks a broken PDF as failed" do
    receipt = upload_content("%PDF-1.4 broken")

    receipt.extract!

    assert receipt.extraction_failed?
    assert_equal "unreadable_pdf", receipt.extraction_error
  end

  test "match candidates are transactions with the amount near the date on writable accounts" do
    receipt = upload([ "Total 42.00" ])
    receipt.update!(amount: 42, currency: "USD", date: Date.current)
    near = create_transaction(account: @account, amount: 42, date: 3.days.ago.to_date)
    create_transaction(account: @account, amount: 41, date: Date.current)
    create_transaction(account: @account, amount: 42, date: 40.days.ago.to_date)
    shared_read_only = create_transaction(account: accounts(:credit_card), amount: 42, date: Date.current)

    assert_equal [ shared_read_only, near ], receipt.match_candidates(@admin).to_a
    assert_equal [ near ], receipt.match_candidates(@member).to_a
  end

  test "link_to! copies the file onto the transaction" do
    receipt = upload([ "Total 9.99" ])
    transaction = create_transaction(account: @account, amount: 9.99, date: Date.current)

    receipt.link_to!(transaction, user: @admin)

    assert_equal transaction, receipt.reload.linked_transaction
    assert_equal :linked, receipt.status
    assert_equal 1, transaction.attachments.count
    assert_not_equal receipt.file.blob_id, transaction.attachments.first.blob_id

    receipt.destroy!
    assert_equal 1, transaction.reload.attachments.count
  end

  test "link_to! refuses an account the user cannot write to" do
    receipt = upload([ "Total 9.99" ])
    transaction = create_transaction(account: accounts(:credit_card), amount: 9.99, date: Date.current)

    assert_raises(ActiveRecord::RecordNotFound) { receipt.link_to!(transaction, user: @member) }
    assert_nil receipt.reload.transaction_id
  end

  test "link_to! refuses a transaction that is full" do
    receipt = upload([ "Total 9.99" ])
    transaction = create_transaction(account: @account, amount: 9.99, date: Date.current)
    Transaction::MAX_ATTACHMENTS_PER_TRANSACTION.times do |index|
      transaction.attachments.attach(io: StringIO.new("%PDF-1.4 #{index}"), filename: "a#{index}.pdf", content_type: "application/pdf")
    end

    assert_raises(ActiveRecord::RecordInvalid) { receipt.link_to!(transaction, user: @admin) }
    assert_nil receipt.reload.transaction_id
  end

  test "create_transaction! records an expense, links it and marks it as created from the receipt" do
    receipt = upload([ "Total 15.00" ])

    entry = nil
    assert_difference -> { @account.entries.count }, 1 do
      entry = receipt.create_transaction!(account: @account, user: @admin, name: "Bakery", date: Date.current, amount: BigDecimal("15"), currency: "USD")
    end

    assert_equal BigDecimal("15"), entry.amount
    assert_equal "Bakery", entry.name
    assert receipt.reload.created_transaction?
    assert_equal entry.transaction, receipt.linked_transaction
    assert entry.transaction.created_from_receipt?
    assert_equal 1, entry.transaction.attachments.count
  end

  test "a linked receipt cannot be linked again or recorded twice" do
    receipt = upload([ "Total 15.00" ])
    receipt.create_transaction!(account: @account, user: @admin, name: "Bakery", date: Date.current, amount: BigDecimal("15"), currency: "USD")
    other = create_transaction(account: @account, amount: 15, date: Date.current)

    assert_raises(ActiveRecord::RecordInvalid) { receipt.link_to!(other, user: @admin) }
    assert_no_difference -> { @account.entries.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        receipt.create_transaction!(account: @account, user: @admin, name: "Bakery", date: Date.current, amount: BigDecimal("15"), currency: "USD")
      end
    end
    assert_equal 0, other.attachments.count
  end

  test "create_transaction! refuses an unknown currency" do
    receipt = upload([ "Total 15.00" ])

    assert_raises(ActiveRecord::RecordInvalid) do
      receipt.create_transaction!(account: @account, user: @admin, name: "Shop", date: Date.current, amount: BigDecimal("15"), currency: "XYZ")
    end
    assert_nil receipt.reload.transaction_id
  end

  test "create_transaction! refuses an amount that is not positive" do
    receipt = upload([ "Total 15.00" ])

    assert_no_difference -> { @account.entries.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        receipt.create_transaction!(account: @account, user: @admin, name: "Refund", date: Date.current, amount: BigDecimal("-15"), currency: "USD")
      end
    end
  end

  test "extract! records an unexpected error without the receipt's text" do
    receipt = upload([ "Total 1.00" ])
    Receipt::Extraction.any_instance.stubs(:run).raises(NoMethodError, "secret text")

    assert_difference -> { DebugLogEntry.count }, 1 do
      receipt.extract!
    end

    assert receipt.extraction_failed?
    assert_equal "unexpected_error", receipt.extraction_error
    assert_not_includes DebugLogEntry.last.message, "secret text"
  end

  test "deleting the transaction returns the receipt to the inbox" do
    receipt = upload([ "Total 15.00" ])
    entry = receipt.create_transaction!(account: @account, user: @admin, name: "Bakery", date: Date.current, amount: BigDecimal("15"), currency: "USD")

    entry.destroy!

    assert_nil receipt.reload.transaction_id
    assert_includes @family.receipts.open, receipt
  end

  test "dismiss! and reopen! move the receipt between open and done" do
    receipt = upload([ "Total 1.00" ])

    receipt.dismiss!
    assert_includes @family.receipts.done, receipt

    receipt.reopen!
    assert_includes @family.receipts.open, receipt
  end

  private
    def upload(lines)
      upload_content(receipt_pdf(lines))
    end

    def upload_image(content)
      Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt(content, filename: "photo.png", content_type: "image/png"))
    end

    def upload_content(content)
      Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt(content))
    end

    def create_transaction(account:, amount:, date:)
      account.entries.create!(name: "Purchase", date: date, amount: amount, currency: "USD", entryable: Transaction.new).transaction
    end
end
