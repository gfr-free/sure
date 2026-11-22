require "test_helper"
require "net/imap"

class Receipt::ImapFetcherTest < ActiveSupport::TestCase
  include ReceiptMailHelper
  include ActiveJob::TestHelper

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
    @imap.stubs(:capability).returns(%w[IMAP4REV1])
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
    @imap.expects(:uid_store).with([ 7 ], "+FLAGS", [ :Seen, :Deleted ])
    @imap.expects(:expunge)

    with_receipt_inbox(IMAP_ENV) do
      assert_difference -> { ActionMailbox::InboundEmail.count }, 1 do
        assert_equal 1, Receipt::ImapFetcher.new.fetch
      end
    end
  end

  test "expunges only its own messages when the server supports UIDPLUS" do
    source = receipt_mail(to: "receipts+#{'a' * 24}@mail.example.com", from: "a@example.com").to_s
    expect_session(uids: [ 7 ], size: source.bytesize, source: source)
    @imap.stubs(:capability).returns(%w[IMAP4REV1 UIDPLUS])
    @imap.expects(:uid_store).with([ 7 ], "+FLAGS", [ :Seen, :Deleted ])
    @imap.expects(:uid_expunge).with([ 7 ])
    @imap.expects(:expunge).never

    with_receipt_inbox(IMAP_ENV) { assert_equal 1, Receipt::ImapFetcher.new.fetch }
  end

  test "sets aside a message with an empty body and goes on after a storage error" do
    source = receipt_mail(to: "receipts+#{'a' * 24}@mail.example.com", from: "a@example.com").to_s
    expect_session(uids: [ 5, 6, 7 ], size: source.bytesize, source: source)
    @imap.stubs(:uid_fetch).with(5, "BODY.PEEK[]").returns([ fetch_data("BODY[]" => "") ])
    ActionMailbox::InboundEmail.expects(:create_and_extract_message_id!).twice.raises(RuntimeError).then.returns(nil)
    @imap.expects(:uid_store).with(5, "+FLAGS", [ :Seen ])
    @imap.expects(:uid_store).with([ 7 ], "+FLAGS", [ :Seen, :Deleted ])
    @imap.expects(:expunge)

    with_receipt_inbox(IMAP_ENV) do
      assert_equal 1, Receipt::ImapFetcher.new.fetch
    end
    assert DebugLogEntry.where(source: "receipt_imap", message: "Receipt IMAP message not stored: RuntimeError").exists?
  end

  test "an already stored message is not stored again, and its routing is queued again while it is pending" do
    source = receipt_mail(to: "receipts+#{'a' * 24}@mail.example.com", from: "a@example.com").to_s
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
    inbound.update_column(:status, ActionMailbox::InboundEmail.statuses[:pending])
    expect_session(uids: [ 7 ], size: source.bytesize, source: source)
    @imap.expects(:uid_store).with([ 7 ], "+FLAGS", [ :Seen, :Deleted ])
    @imap.expects(:expunge)

    with_receipt_inbox(IMAP_ENV) do
      assert_no_difference -> { ActionMailbox::InboundEmail.count } do
        assert_enqueued_with(job: ActionMailbox::RoutingJob, args: [ inbound ]) do
          assert_equal 1, Receipt::ImapFetcher.new.fetch
        end
      end
    end
  end

  test "a message whose routing cannot be queued stays unread" do
    source = receipt_mail(to: "receipts+#{'a' * 24}@mail.example.com", from: "a@example.com").to_s
    ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
    expect_session(uids: [ 7 ], size: source.bytesize, source: source)
    ActionMailbox::InboundEmail.any_instance.stubs(:route_later).raises(RuntimeError)
    @imap.expects(:uid_store).never

    with_receipt_inbox(IMAP_ENV) { assert_equal 0, Receipt::ImapFetcher.new.fetch }
  end

  test "closes the connection when the login is refused" do
    Net::IMAP.expects(:new).returns(@imap)
    @imap.expects(:login).raises(Net::IMAP::NoResponseError.new(Struct.new(:data).new(Struct.new(:text).new("refused"))))
    @imap.expects(:disconnect)

    with_receipt_inbox(IMAP_ENV) { assert_equal 0, Receipt::ImapFetcher.new.fetch }
  end

  test "a blank port falls back to 993" do
    with_env_overrides(IMAP_ENV.merge("RECEIPT_INBOX_IMAP_PORT" => "")) do
      assert_equal 993, Receipt::ImapFetcher.settings[:port]
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
