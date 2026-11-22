require "test_helper"

class Receipt::ExtractionAiTest < ActiveSupport::TestCase
  include ReceiptPdfHelper

  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
  ANSWER = { merchant_name: "Coffee House", currency: "EUR", date: "2026-11-20", line_items: [], tax: nil, discount: nil, total: 12.4 }.freeze

  setup do
    travel_to Date.new(2026, 11, 22)
    @family = families(:dylan_family)
    @user = users(:family_admin)
    use_ai_routes(extract_receipt: %w[openai/gpt-4.1-mini])
  end

  test "a photo is read by AI when the uploader has AI on" do
    requests = stub_ai(:extract_receipt, returns: ANSWER)
    receipt = upload(PNG, filename: "bon.png", content_type: "image/png")

    receipt.extract!

    assert_equal 1, requests.size
    assert_equal "image/png", requests.first.attachments.first.content_type
    assert receipt.extraction_completed?
    assert_equal "Coffee House", receipt.merchant_name
    assert_equal BigDecimal("12.4"), receipt.amount
    assert_equal "EUR", receipt.currency
    assert_equal Date.new(2026, 11, 20), receipt.date
    assert_equal "ai", receipt.field_source(:amount)
    assert_equal 0.6, receipt.field_confidence(:amount)
  end

  test "a PDF whose text gives amount and date is not sent to AI" do
    requests = stub_ai(:extract_receipt, returns: ANSWER)
    receipt = upload(receipt_pdf([ "Coffee House", "Total 12.40 USD", "Date 2026-11-20" ]))

    receipt.extract!

    assert_empty requests
    assert_equal "pdf_text", receipt.field_source(:amount)
  end

  test "AI fills only what the text left missing, checked against that text" do
    requests = stub_ai(:extract_receipt, returns: ANSWER.merge(total: 99))
    receipt = upload(receipt_pdf([ "Coffee House", "Total 12.40 USD" ]))

    receipt.extract!

    assert_equal 1, requests.size
    assert_equal BigDecimal("12.40"), receipt.amount
    assert_equal "pdf_text", receipt.field_source(:amount)
    assert_equal Date.new(2026, 11, 20), receipt.date
    assert_equal "ai", receipt.field_source(:date)
    # The text holds no such date, so the AI's reading counts as unsure.
    assert_equal 0.4, receipt.field_confidence(:date)
  end

  test "nothing is sent without the uploader's AI switch" do
    @user.update!(ai_enabled: false)
    requests = stub_ai(:extract_receipt, returns: ANSWER)
    receipt = upload(PNG, filename: "bon.png", content_type: "image/png")

    receipt.extract!

    assert_empty requests
    assert receipt.extraction_completed?
    assert_nil receipt.amount
  end

  test "an AI failure leaves the fields blank and logs only the error class" do
    stub_ai(:extract_receipt, raises: Ai::Error::Timeout.new("timed out reading Coffee House"))
    receipt = upload(PNG, filename: "bon.png", content_type: "image/png")

    assert_difference -> { DebugLogEntry.where(category: "receipts").count }, 1 do
      receipt.extract!
    end

    assert receipt.extraction_completed?
    assert_nil receipt.amount
    entry = DebugLogEntry.where(category: "receipts").order(:created_at).last
    assert_includes entry.message, "Ai::Error::Timeout"
    assert_not_includes entry.message, "Coffee House"
  end

  test "a model that cannot read the file is skipped without a log entry" do
    use_ai_routes(extract_receipt: %w[gpu/qwen3-8b])
    requests = stub_ai(:extract_receipt, returns: ANSWER)
    receipt = upload(PNG, filename: "bon.png", content_type: "image/png")

    assert_no_difference -> { DebugLogEntry.where(category: "receipts").count } do
      receipt.extract!
    end

    assert_empty requests
    assert receipt.extraction_completed?
  end

  test "an unexpected error in the AI step keeps what the text stage read" do
    Ai::Generations::ExtractReceipt.any_instance.stubs(:call).raises(NoMethodError, "boom")
    receipt = upload(receipt_pdf([ "Coffee House", "Total 12.40 USD" ]))

    receipt.extract!

    assert receipt.extraction_completed?
    assert_equal BigDecimal("12.40"), receipt.amount
    assert_equal "pdf_text", receipt.field_source(:amount)
  end

  test "a text PDF sends its masked text, not the file" do
    requests = stub_ai(:extract_receipt, returns: ANSWER)
    receipt = upload(receipt_pdf([ "Coffee House", "Total 12.40 USD", "Card 4111 1111 1111 1234" ]))

    receipt.extract!

    assert_empty requests.first.attachments
    assert_includes requests.first.input.to_s, "****1234"
    assert_not_includes requests.first.input.to_s, "4111 1111"
  end

  private
    def upload(content, filename: "receipt.pdf", content_type: "application/pdf")
      Receipt.create_from_upload!(family: @family, user: @user, file: uploaded_receipt(content, filename:, content_type:))
    end
end
