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
    assert_not receipt.fields_read?
    assert_equal :open, receipt.status
  end

  test "extract! reads a till receipt's QR code on a photo" do
    require_qr_tools!
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
      assert receipt.fields_read?
      assert_equal [ "tse" ], receipt.merchant_identifiers.map { |identifier| identifier["kind"] }
    end
  end

  test "extract! takes the merchant from a PDF's text when its QR code has none" do
    require_qr_tools!(pdf: true)
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

  test "a receipt from a till seen before gets the merchant of the earlier receipt's transaction" do
    require_qr_tools!
    travel_to Time.zone.parse("2026-11-22 12:00") do
      first = upload_image(receipt_qr_png(german_till_payload))
      first.extract!
      transaction = create_transaction(account: @account, amount: 11.59, date: Date.current)
      first.link_to!(transaction, user: @admin)
      # A merchant set after linking, by hand or by a rule, counts too.
      transaction.update!(merchant: merchants(:amazon))

      second = upload_image(receipt_qr_png(german_till_payload(gross: "2.10_0.00_0.00_0.00_0.00")))
      second.extract!

      assert_equal "Amazon", second.merchant_name
      assert_equal "qr", second.field_source(:merchant_name)
      assert_equal BigDecimal("2.10"), second.amount

      other_till = upload_image(receipt_qr_png(german_till_payload(serial: "KASSE-02")))
      other_till.extract!
      assert_nil other_till.merchant_name
    end
  end

  test "a learned merchant only comes from transactions the uploader can see" do
    require_qr_tools!
    travel_to Time.zone.parse("2026-11-22 12:00") do
      first = upload_image(receipt_qr_png(german_till_payload))
      first.extract!
      transaction = create_transaction(account: accounts(:credit_card), amount: 11.59, date: Date.current)
      transaction.update!(merchant: merchants(:amazon))
      first.link_to!(transaction, user: @admin)

      AccountShare.where(account: accounts(:credit_card), user: @member).delete_all
      member_receipt = Receipt.create_from_upload!(family: @family, user: @member,
                                                   file: uploaded_receipt(receipt_qr_png(german_till_payload(gross: "1.00_0.00_0.00_0.00_0.00")), filename: "photo.png", content_type: "image/png"))
      member_receipt.extract!
      assert_nil member_receipt.merchant_name

      admin_receipt = upload_image(receipt_qr_png(german_till_payload(gross: "3.00_0.00_0.00_0.00_0.00")))
      admin_receipt.extract!
      assert_equal "Amazon", admin_receipt.merchant_name
    end
  end

  test "extract! keeps a PDF's QR fields when its text layer cannot be read" do
    require_qr_tools!(pdf: true)
    travel_to Time.zone.parse("2026-11-22 12:00") do
      receipt = upload_content(receipt_qr_pdf(german_till_payload))
      Receipt::Extraction.any_instance.stubs(:pdf_text).raises(Receipt::Extraction::Error, "unreadable_pdf")

      receipt.extract!

      assert receipt.extraction_completed?
      assert_equal BigDecimal("11.59"), receipt.amount
    end
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

  test "match candidates keep the amount filter when the currency is unknown" do
    receipt = upload([ "Total 25.00" ])
    receipt.update!(amount: 25, currency: nil, date: nil)
    match = create_transaction(account: @account, amount: 25, date: 5.days.ago.to_date)
    create_transaction(account: @account, amount: 26, date: Date.current)

    assert_equal [ match ], receipt.match_candidates(@admin).to_a
  end

  test "a file named .pdf without PDF bytes is refused" do
    assert_raises(Receipt::InvalidUploadError) do
      Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt("just some text", filename: "receipt.pdf"))
    end
  end

  test "a failed storage write removes the partial file and keeps the error" do
    ActiveStorage::Blob.any_instance.stubs(:upload_without_unfurling).raises(Errno::ENOSPC)
    ActiveStorage::Blob.any_instance.expects(:delete).once.raises(Errno::EIO)

    assert_no_difference [ "Receipt.count", "ActiveStorage::Blob.count" ] do
      assert_raises(Errno::ENOSPC) { upload([ "Total 1.00" ]) }
    end
  end

  test "create_transaction! refuses amounts that round to zero or past the ledger's capacity" do
    receipt = upload([ "Total 15.00" ])

    [ BigDecimal("0.00001"), BigDecimal("999999999999999.99999") ].each do |amount|
      assert_no_difference -> { @account.entries.count } do
        assert_raises(ActiveRecord::RecordInvalid) do
          receipt.create_transaction!(account: @account, user: @admin, name: "Odd", date: Date.current, amount: amount, currency: "USD")
        end
      end
    end
  end

  test "create_transaction! locks the merchant it found for the new transaction" do
    receipt = upload([ "Total 15.00" ])
    merchant = @family.merchants.create!(name: "Bakery")

    entry = receipt.create_transaction!(account: @account, user: @admin, name: "Bakery", date: Date.current, amount: BigDecimal("15"), currency: "USD")

    assert_equal merchant, entry.transaction.reload.merchant
    assert entry.transaction.locked?(:merchant_id)
  end

  test "update_fields! leaves fields the form showed unchanged alone" do
    receipt = upload([ "Total 15.00" ])
    receipt.update!(amount: 15, date: Date.new(2026, 11, 20))

    receipt.update_fields!({ "merchant_name" => "Bakery", "amount" => "", "date" => "", "currency" => "USD" },
                           { "merchant_name" => "", "amount" => "", "date" => "", "currency" => "USD" })

    assert_equal "Bakery", receipt.reload.merchant_name
    assert_equal BigDecimal("15"), receipt.amount
    assert_equal Date.new(2026, 11, 20), receipt.date

    receipt.update_fields!({ "amount" => "" }, { "amount" => "15.00" })
    assert_nil receipt.reload.amount
  end

  test "a transaction created from a receipt stays marked after the receipt is deleted" do
    receipt = upload([ "Total 15.00" ])
    entry = receipt.create_transaction!(account: @account, user: @admin, name: "Bakery", date: Date.current, amount: BigDecimal("15"), currency: "USD")

    receipt.destroy!

    assert entry.transaction.reload.created_from_receipt?
  end

  test "an uploader's receipts follow them to a new family; links left behind are dropped" do
    own_account = Account.create!(family: @family, owner: @member, name: "Own Checking", balance: 0, currency: "USD", accountable: Depository.new)
    follows = Receipt.create_from_upload!(family: @family, user: @member, file: uploaded_receipt(receipt_pdf([ "Total 1.00" ])))
    follows.link_to!(create_transaction(account: own_account, amount: 1, date: Date.current), user: @member)
    left_behind_transaction = create_transaction(account: @account, amount: 2, date: Date.current)
    stays = Receipt.create_from_upload!(family: @family, user: @member, file: uploaded_receipt(receipt_pdf([ "Total 2.00" ])))
    stays.link_to!(left_behind_transaction, user: @member)
    new_family = Family.create!(name: "Moved Family")

    @member.transfer_to_family!(new_family, role: "admin")

    assert_equal new_family, follows.reload.family
    assert follows.transaction_id?
    assert_equal new_family, stays.reload.family
    assert_not stays.transaction_id?
    assert_equal 1, left_behind_transaction.attachments.count
  end

  test "another member's receipt drops its link to an account that moves to a new family" do
    own_account = Account.create!(family: @family, owner: @member, name: "Own Checking", balance: 0, currency: "USD", accountable: Depository.new)
    moved_transaction = create_transaction(account: own_account, amount: 3, date: Date.current)
    stays = upload([ "Total 3.00" ])
    stays.update_columns(transaction_id: moved_transaction.id, linked_at: Time.current)

    @member.transfer_to_family!(Family.create!(name: "Moved Family"), role: "admin")

    assert_equal @family, stays.reload.family
    assert_not stays.transaction_id?
    assert stays.valid?
  end

  test "purging an uploader removes their receipts but keeps the transaction's copy" do
    receipt = Receipt.create_from_upload!(family: @family, user: @member, file: uploaded_receipt(receipt_pdf([ "Total 9.99" ])))
    transaction = create_transaction(account: @account, amount: 9.99, date: Date.current)
    receipt.link_to!(transaction, user: @member)

    @member.purge

    assert_not Receipt.exists?(receipt.id)
    assert_equal 1, transaction.reload.attachments.count
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
    ActiveStorage::Blob.any_instance.stubs(:upload_without_unfurling).raises(Errno::ECONNREFUSED)

    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(Errno::ECONNREFUSED) { receipt.link_to!(transaction, user: @admin) }
    end
    assert_nil receipt.reload.transaction_id
    assert_equal 0, transaction.reload.attachments.count
  end

  test "an upload that cannot be stored leaves no receipt, so the same file can be tried again" do
    content = receipt_pdf([ "Total 4.20" ])
    ActiveStorage::Blob.any_instance.stubs(:upload_without_unfurling).raises(Errno::ECONNREFUSED)

    assert_no_difference [ "Receipt.count", "ActiveStorage::Blob.count" ] do
      assert_raises(Errno::ECONNREFUSED) { upload_content(content) }
    end

    ActiveStorage::Blob.any_instance.unstub(:upload_without_unfurling)
    assert upload_content(content).file.attached?
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

  test "link_to! and create_transaction! check write access again once the copy is stored" do
    receipt = upload([ "Total 9.99" ])
    transaction = create_transaction(account: @account, amount: 9.99, date: Date.current)
    receipt.stubs(:writable_account?).returns(true).then.returns(false)

    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(ActiveRecord::RecordNotFound) { receipt.link_to!(transaction, user: @admin) }
    end
    assert_equal 0, transaction.reload.attachments.count

    receipt.stubs(:writable_account?).returns(true).then.returns(false)
    assert_no_difference [ "Entry.count", "ActiveStorage::Blob.count" ] do
      assert_raises(ActiveRecord::RecordNotFound) do
        receipt.create_transaction!(account: @account, user: @admin, name: "Bakery", date: Date.current, amount: BigDecimal("9.99"), currency: "USD")
      end
    end
    assert_nil receipt.reload.transaction_id
  end

  test "an upload stays stored when a step after the commit fails" do
    Receipt.any_instance.stubs(:extract_later).raises(RuntimeError, "queue down")

    receipt = upload([ "Total 4.20" ])

    assert receipt.persisted?
    assert receipt.reload.file.attached?
  end

  test "a failed cleanup does not hide why the upload failed" do
    Receipt.any_instance.stubs(:save!).raises(ArgumentError, "save failed")
    ActiveStorage::Blob.any_instance.stubs(:purge).raises(Errno::ECONNREFUSED)

    error = assert_raises(ArgumentError) { upload([ "Total 4.20" ]) }
    assert_equal "save failed", error.message
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

  test "create_transaction! finishes the new entry even when the account sync cannot be queued" do
    receipt = upload([ "Total 15.00" ])
    Entry.any_instance.stubs(:sync_account_later).raises(RedisClient::CannotConnectError)
    Rule.expects(:apply_immediately_later).once

    entry = receipt.create_transaction!(account: @account, user: @admin, name: "Bakery", date: Date.current, amount: BigDecimal("15"), currency: "USD")

    assert entry.reload.user_modified?
    assert entry.locked?(:amount)
    assert_equal entry.transaction, receipt.reload.linked_transaction
  end

  test "a receipt whose reading cannot be queued is marked failed" do
    ReceiptExtractionJob.stubs(:perform_later).raises(RedisClient::CannotConnectError)

    receipt = upload([ "Total 2.00" ])

    assert receipt.reload.extraction_failed?
    assert_equal "enqueue_failed", receipt.extraction_error
  end

  test "a receipt whose job is silently not enqueued is marked failed" do
    ReceiptExtractionJob.stubs(:perform_later).returns(false)

    receipt = upload([ "Total 2.00" ])

    assert receipt.reload.extraction_failed?
    assert_equal "enqueue_failed", receipt.extraction_error
  end

  test "extract! marks the receipt failed when a read value cannot be saved" do
    receipt = upload([ "Total 2.00" ])
    result = Receipt::Extraction::Result.new(fields: { "amount" => { value: BigDecimal("1e16"), confidence: 0.9, source: "pdf_text" } }, raw_text: "x")
    Receipt::Extraction.any_instance.stubs(:run).returns(result)

    receipt.extract!

    assert receipt.reload.extraction_failed?
    assert_nil receipt.amount
  end

  test "extract! masks a card number read as the merchant" do
    receipt = upload([ "Total 2.00" ])
    Receipt::TextParser.stubs(:parse).returns({ "merchant_name" => { value: "Shop 4111 1111 1111 1234", confidence: 0.3 } })

    receipt.extract!

    assert_equal "Shop ****1234", receipt.reload.merchant_name
  end

  test "link_to! does not link when the transaction refuses the attachment" do
    receipt = upload([ "Total 9.99" ])
    transaction = create_transaction(account: @account, amount: 9.99, date: Date.current)
    ActiveStorage::Attached::Many.any_instance.stubs(:attach).returns(false)

    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(ActiveRecord::RecordInvalid) { receipt.link_to!(transaction, user: @admin) }
    end
    assert_nil receipt.reload.transaction_id
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

  test "create_transaction! refuses an amount too large to store" do
    receipt = upload([ "Total 2.00" ])

    assert_no_difference -> { @account.entries.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        receipt.create_transaction!(account: @account, user: @admin, name: "Huge", date: Date.current, amount: BigDecimal("1e20"), currency: "USD")
      end
    end
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
