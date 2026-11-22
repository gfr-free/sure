require "test_helper"

class ReceiptTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ReceiptPdfHelper

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

  test "extract! leaves an image's fields blank until a reader for images exists" do
    receipt = Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt(file_fixture("square-placeholder.png").binread, filename: "photo.png", content_type: "image/png"))

    receipt.extract!

    assert receipt.extraction_completed?
    assert_nil receipt.amount
    assert_nil receipt.raw_text
    assert_equal :open, receipt.status
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

  test "link_to! fails without linking when the copy cannot be stored" do
    receipt = upload([ "Total 9.99" ])
    transaction = create_transaction(account: @account, amount: 9.99, date: Date.current)
    ActiveStorage::Blob.stubs(:create_and_upload!).raises(Errno::ECONNREFUSED)

    assert_raises(Errno::ECONNREFUSED) { receipt.link_to!(transaction, user: @admin) }
    assert_nil receipt.reload.transaction_id
    assert_equal 0, transaction.reload.attachments.count
  end

  test "a refused link removes the copy it uploaded" do
    receipt = upload([ "Total 9.99" ])
    other = create_transaction(account: @account, amount: 9.99, date: Date.current)
    receipt.link_to!(other, user: @admin)
    transaction = create_transaction(account: @account, amount: 9.99, date: Date.current)

    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(ActiveRecord::RecordInvalid) { receipt.link_to!(transaction, user: @admin) }
    end
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

  test "extract! reads an XRechnung XML file with its invoice details" do
    receipt = upload_xml(e_invoice_xml("ubl_invoice"))
    assert receipt.xml?

    receipt.extract!

    assert receipt.extraction_completed?
    assert_equal "Demo Energy AG", receipt.merchant_name
    assert_equal Date.new(2026, 10, 30), receipt.date
    assert_equal BigDecimal("49.98"), receipt.amount
    assert_equal "EUR", receipt.currency
    assert_equal "DEMO-UBL-7", receipt.invoice_number
    assert_equal Date.new(2026, 11, 13), receipt.due_date
    assert_equal BigDecimal("7.98"), receipt.tax_amount
    assert_equal "einvoice", receipt.field_source(:amount)
    assert_equal 1.0, receipt.field_confidence(:amount)
    assert receipt.read_any_field?
  end

  test "extract! takes a hybrid PDF's values from its XML, not its printed text" do
    travel_to Date.new(2026, 11, 22) do
      receipt = upload_content(receipt_pdf([ "Other Shop", "Total 5.00", "Date 2026-11-20" ], attachments: { "factur-x.xml" => e_invoice_xml("cii_invoice") }))

      receipt.extract!

      assert_equal "Demo Supplies GmbH", receipt.merchant_name
      assert_equal BigDecimal("119.00"), receipt.amount
      assert_equal Date.new(2026, 11, 5), receipt.date
      assert_equal "einvoice", receipt.field_source(:merchant_name)
      assert_nil receipt.raw_text
    end
  end

  test "extract! does not guess a credit note's amount from the PDF text" do
    travel_to Date.new(2026, 11, 22) do
      credit_note = e_invoice_xml("cii_invoice").sub("<ram:TypeCode>380", "<ram:TypeCode>381")
      receipt = upload_content(receipt_pdf([ "Credit note", "Total 119.00" ], attachments: { "factur-x.xml" => credit_note }))

      receipt.extract!

      assert_equal "Demo Supplies GmbH", receipt.merchant_name
      assert_nil receipt.amount
      assert_nil receipt.tax_amount
    end
  end

  test "extract! fills what the e-invoice lacks from the PDF text, except the amount" do
    travel_to Date.new(2026, 11, 22) do
      xml = e_invoice_xml("cii_invoice").sub('format="102">20261105', 'format="610">202611').sub("<ram:GrandTotalAmount>119.00", "<ram:GrandTotalAmount>n/a")
      receipt = upload_content(receipt_pdf([ "Other Shop", "Total 5.00", "Date 2026-11-20" ], attachments: { "factur-x.xml" => xml }))

      receipt.extract!

      assert_equal "Demo Supplies GmbH", receipt.merchant_name
      assert_equal Date.new(2026, 11, 20), receipt.date
      assert_equal "pdf_text", receipt.field_source(:date)
      assert_nil receipt.amount
    end
  end

  test "extract! still reads the PDF text when the e-invoice reader fails" do
    travel_to Date.new(2026, 11, 22) do
      receipt = upload([ "Coffee House", "Total 12.40 USD", "Date 2026-11-20" ])
      Receipt::EInvoice.stubs(:from_pdf).raises(NoMethodError)

      assert_difference -> { DebugLogEntry.where(source: "receipt_extraction").count }, 1 do
        receipt.extract!
      end

      assert receipt.extraction_completed?
      assert_equal BigDecimal("12.40"), receipt.amount
    end
  end

  test "extract! fails an XML receipt whose file cannot be downloaded" do
    receipt = upload_xml(e_invoice_xml("ubl_invoice"))
    ActiveStorage::Blob.any_instance.stubs(:download).raises(Errno::ECONNRESET)

    receipt.extract!

    assert receipt.extraction_failed?
    assert_nil receipt.amount
  end

  test "the tax is shown only while the currency is the e-invoice's" do
    receipt = upload_xml(e_invoice_xml("ubl_invoice").sub(">7.98<", ">0.00<"))
    receipt.extract!

    assert_equal Money.new(0, "EUR"), receipt.tax_money
    assert receipt.invoice_details?

    receipt.update_fields!(currency: "USD")
    assert_nil receipt.tax_money
  end

  test "extract! clears invoice details the file no longer has" do
    receipt = upload([ "Total 1.00" ])
    receipt.update!(invoice_number: "OLD-1", due_date: Date.current, tax_amount: 1)

    receipt.extract!

    assert_nil receipt.invoice_number
    assert_nil receipt.due_date
    assert_nil receipt.tax_amount
  end

  test "an XML that is not an e-invoice completes with nothing read" do
    receipt = upload_xml("<note><to>Demo</to></note>")

    receipt.extract!

    assert receipt.extraction_completed?
    assert_nil receipt.amount
    assert_not receipt.read_any_field?
  end

  test "link_to! attaches an e-invoice XML to the transaction" do
    receipt = upload_xml(e_invoice_xml("ubl_invoice"))
    transaction = create_transaction(account: @account, amount: 49.98, date: Date.current)

    receipt.link_to!(transaction, user: @admin)

    assert_equal 1, transaction.reload.attachments.count
    assert_includes Transaction::XML_CONTENT_TYPES, transaction.attachments.first.content_type
  end

  private
    def upload_xml(content)
      Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt(content, filename: "invoice.xml", content_type: "application/xml"))
    end

    def upload(lines)
      upload_content(receipt_pdf(lines))
    end

    def upload_content(content)
      Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt(content))
    end

    def create_transaction(account:, amount:, date:)
      account.entries.create!(name: "Purchase", date: date, amount: amount, currency: "USD", entryable: Transaction.new).transaction
    end
end
