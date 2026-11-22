require "test_helper"
require "net/imap"

class Receipt::ImapFetcherTest < ActiveSupport::TestCase
  include ReceiptMailHelper

  IMAP_ENV = {
    "RECEIPT_INBOX_IMAP_HOST" => "imap.example.com",
    "RECEIPT_INBOX_IMAP_USERNAME" => "receipts",
    "RECEIPT_INBOX_IMAP_PASSWORD" => "secret"
  }.freeze

  setup do
    @imap = mock("imap")
    @imap.stubs(:disconnected?).returns(false)
    @imap.stubs(:logout)
    @imap.stubs(:disconnect)
  end

  test "is configured only with a base address and IMAP credentials" do
    with_receipt_inbox { assert_not Receipt::ImapFetcher.configured? }
    with_receipt_inbox(IMAP_ENV) { assert Receipt::ImapFetcher.configured? }
    with_env_overrides(IMAP_ENV.merge("RECEIPT_INBOX_ADDRESS" => nil)) { assert_not Receipt::ImapFetcher.configured? }
  end

  test "the job does nothing until IMAP is configured" do
    Net::IMAP.expects(:new).never

    with_receipt_inbox { ReceiptInboxImapJob.perform_now }
  end

  test "hands unread mail to Action Mailbox, then deletes it from the mailbox" do
    source = receipt_mail(to: "receipts+#{'a' * 24}@mail.example.com", from: "a@example.com").to_s
    expect_session(uids: [ 7 ], size: source.bytesize, source: source)
    @imap.expects(:uid_store).with(7, "+FLAGS", [ :Seen, :Deleted ])
    @imap.expects(:expunge)

    with_receipt_inbox(IMAP_ENV) do
      assert_difference -> { ActionMailbox::InboundEmail.count }, 1 do
        assert_equal 1, Receipt::ImapFetcher.new.fetch
      end
    end
  end

  test "only marks mail as read when the operator keeps it" do
    source = receipt_mail(to: "receipts+#{'a' * 24}@mail.example.com", from: "a@example.com").to_s
    expect_session(uids: [ 7 ], size: source.bytesize, source: source)
    @imap.expects(:uid_store).with(7, "+FLAGS", [ :Seen ])
    @imap.expects(:expunge).never

    with_receipt_inbox(IMAP_ENV.merge("RECEIPT_INBOX_IMAP_KEEP" => "true")) do
      assert_equal 1, Receipt::ImapFetcher.new.fetch
    end
  end

  test "skips oversized mail without downloading it" do
    expect_session(uids: [ 9 ], size: Receipt::ImapFetcher::MAX_MESSAGE_BYTES + 1, source: nil)
    @imap.expects(:uid_store).with(9, "+FLAGS", [ :Seen ])
    @imap.expects(:expunge).never

    with_receipt_inbox(IMAP_ENV) do
      assert_no_difference -> { ActionMailbox::InboundEmail.count } do
        assert_equal 0, Receipt::ImapFetcher.new.fetch
      end
    end
  end

  test "logs a failed connection without the credentials" do
    Net::IMAP.expects(:new).raises(Errno::ECONNREFUSED)

    with_receipt_inbox(IMAP_ENV) do
      assert_difference -> { DebugLogEntry.where(source: "receipt_imap").count }, 1 do
        assert_equal 0, Receipt::ImapFetcher.new.fetch
      end
    end
    assert_not_includes DebugLogEntry.where(source: "receipt_imap").last.message, "secret"
  end

  private
    def expect_session(uids:, size:, source:)
      Net::IMAP.expects(:new).with("imap.example.com", has_entries(port: 993, ssl: { verify_mode: OpenSSL::SSL::VERIFY_PEER })).returns(@imap)
      @imap.expects(:login).with("receipts", "secret")
      @imap.expects(:select).with("INBOX")
      @imap.expects(:uid_search).with([ "UNSEEN" ]).returns(uids)
      uids.each do |uid|
        @imap.stubs(:uid_fetch).with(uid, "RFC822.SIZE").returns([ fetch_data("RFC822.SIZE" => size) ])
        @imap.stubs(:uid_fetch).with(uid, "BODY.PEEK[]").returns([ fetch_data("BODY[]" => source) ]) if source
      end
    end

    def fetch_data(attr)
      Struct.new(:attr).new(attr)
    end
end
