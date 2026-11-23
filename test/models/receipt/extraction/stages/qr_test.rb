require "test_helper"

class Receipt::Extraction::Stages::QrTest < ActiveSupport::TestCase
  include ReceiptPdfHelper
  include ReceiptQrHelper

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @account = accounts(:depository)
    # The other stages of the series are left out, so these tests see what the
    # QR codes and the PDF text give.
    Receipt::Extraction.stubs(:stages).returns([ Receipt::Extraction::Stages::Qr, Receipt::Extraction::Stages::PdfText ])
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

  private
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
