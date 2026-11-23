require "test_helper"

class Receipt::Extraction::Stages::OcrTest < ActiveSupport::TestCase
  include ReceiptPdfHelper

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    # The other stages of the series are left out, so these tests see what the
    # PDF text and text recognition give.
    Receipt::Extraction.stubs(:stages).returns([ Receipt::Extraction::Stages::PdfText, Receipt::Extraction::Stages::Ocr ])
  end

  test "extract! leaves an image's fields blank without text recognition and says why" do
    Receipt::Ocr.stubs(:available?).returns(false)
    Receipt::Ocr.any_instance.expects(:read_image).never
    receipt = upload_photo

    receipt.extract!

    assert receipt.extraction_completed?
    assert_nil receipt.amount
    assert_nil receipt.raw_text
    assert_equal :open, receipt.status
    assert receipt.text_recognition_unavailable?
  end

  test "extract! reads a photo with text recognition" do
    card = "4242" * 4
    Receipt::Ocr.stubs(:available?).returns(true)
    Receipt::Ocr.any_instance.expects(:read_image).with(anything, content_type: "image/png").returns(
      Receipt::Ocr::Result.new(text: "Corner Bakery\nTOTAL 8.40 USD\nDate #{Date.current.iso8601} 09:12\nVISA #{card}", confidence: 0.8)
    )
    receipt = upload_photo

    receipt.extract!

    assert receipt.extraction_completed?
    assert_equal BigDecimal("8.40"), receipt.amount
    assert_equal Date.current, receipt.date
    assert_equal "ocr", receipt.field_source(:amount)
    # The rule's 70% is scaled by Tesseract's 80% word confidence.
    assert_equal 0.56, receipt.field_confidence(:amount)
    assert_includes receipt.raw_text, "Corner Bakery"
    assert_not_includes receipt.raw_text, card
    assert_not receipt.text_recognition_unavailable?
  end

  test "extract! recognizes a scanned PDF only when it has no text layer" do
    Receipt::Ocr.stubs(:pdf_available?).returns(true)
    Receipt::Ocr.any_instance.expects(:read_pdf).with(anything, max_pages: Receipt::Extraction::MAX_PDF_PAGES)
                .returns(Receipt::Ocr::Result.new(text: "Total 3.10 USD\nDate #{Date.current.iso8601}", confidence: 1.0))
    scan = upload([ "Page 1" ])

    scan.extract!

    assert_equal BigDecimal("3.10"), scan.amount
    assert_equal "ocr", scan.field_source(:date)

    Receipt::Ocr.any_instance.expects(:read_pdf).never
    text_pdf = upload([ "Coffee House", "Total 12.40 USD" ])
    text_pdf.extract!

    assert_equal BigDecimal("12.40"), text_pdf.amount
    assert_nil text_pdf.date
  end

  test "extract! takes the currency from the stage that read the amount" do
    Receipt::Ocr.stubs(:pdf_available?).returns(true)
    Receipt::Ocr.any_instance.expects(:read_pdf)
                .returns(Receipt::Ocr::Result.new(text: "Total 20.00 USD\nDate #{Date.current.iso8601}", confidence: 1.0))
    scan = upload([ "Total 0.00 EUR" ])

    scan.extract!

    assert_equal BigDecimal("20.00"), scan.amount
    assert_equal "USD", scan.currency
  end

  test "extract! keeps what the PDF text gave when text recognition fails" do
    Receipt::Ocr.stubs(:pdf_available?).returns(true)
    Receipt::Ocr.any_instance.expects(:read_pdf).raises(Receipt::Ocr::Error.new("ocr_timeout"))
    receipt = upload([ "Total 1.00" ])

    assert_difference -> { DebugLogEntry.where(source: "receipt_ocr").count }, 1 do
      receipt.extract!
    end

    assert receipt.extraction_completed?
    assert_equal BigDecimal("1.00"), receipt.amount
    assert_equal "ocr_timeout", receipt.extraction_error
    assert_not receipt.text_recognition_unavailable?
  end

  test "extract! says text recognition is missing for a scan when only pdftoppm is" do
    Receipt::Ocr.stubs(:available?).returns(true)
    Receipt::Ocr.stubs(:pdf_available?).returns(false)
    receipt = upload([])

    receipt.extract!

    assert receipt.extraction_completed?
    assert receipt.text_recognition_unavailable?
  end

  test "extract! marks a photo as failed when text recognition gives up" do
    Receipt::Ocr.stubs(:available?).returns(true)
    Receipt::Ocr.any_instance.expects(:read_image).raises(Receipt::Ocr::Error.new("ocr_timeout"))
    receipt = upload_photo

    receipt.extract!

    assert receipt.extraction_failed?
    assert_equal "ocr_timeout", receipt.extraction_error
  end

  private
    def upload(lines)
      Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt(receipt_pdf(lines)))
    end

    def upload_photo
      Receipt.create_from_upload!(family: @family, user: @admin, file: uploaded_receipt(file_fixture("square-placeholder.png").binread, filename: "photo.png", content_type: "image/png"))
    end
end
