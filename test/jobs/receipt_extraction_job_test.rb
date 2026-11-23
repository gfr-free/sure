require "test_helper"

class ReceiptExtractionJobTest < ActiveJob::TestCase
  include ReceiptPdfHelper

  test "a failed match keeps the finished reading and does not fail the job" do
    user = users(:family_admin)
    receipt = Receipt.create_from_upload!(family: user.family, user: user, file: uploaded_receipt(receipt_pdf([ "Total 4.50" ])))
    receipt.stubs(:auto_match!).raises(ActiveRecord::Deadlocked)

    assert_difference -> { DebugLogEntry.where(source: "receipt_auto_match").count }, 1 do
      ReceiptExtractionJob.perform_now(receipt)
    end
    assert receipt.reload.extraction_completed?
  end
end
