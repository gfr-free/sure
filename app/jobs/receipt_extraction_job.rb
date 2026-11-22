class ReceiptExtractionJob < ApplicationJob
  queue_as :medium_priority

  def perform(receipt)
    receipt.extract!
    receipt.auto_match!
  end
end
