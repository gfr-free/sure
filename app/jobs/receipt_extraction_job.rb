class ReceiptExtractionJob < ApplicationJob
  queue_as :medium_priority

  def perform(receipt)
    receipt.extract!
    match(receipt)
  end

  private
    # Matching is a follow-up that every sync repeats, so its failure must not
    # retry the job: a second read could turn the finished reading into "failed".
    def match(receipt)
      receipt.auto_match!
    rescue StandardError => e
      DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt##{receipt.id}: auto match after reading failed: #{e.class}",
                            source: "receipt_auto_match", family: receipt.family, user_id: receipt.uploaded_by_id)
    end
end
