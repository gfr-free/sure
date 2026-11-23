class ReceiptExtractionJob < ApplicationJob
  queue_as :medium_priority

  def perform(receipt)
    receipt.extract!
  end
end
