class ReceiptInboxImapJob < ApplicationJob
  queue_as :scheduled

  def perform
    return unless Receipt::ImapFetcher.configured?

    Receipt::ImapFetcher.new.fetch
  end
end
