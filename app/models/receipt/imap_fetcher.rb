# frozen_string_literal: true

require "net/imap"

# Collects receipt mail from an IMAP mailbox the operator names, for setups
# without a public mail ingress. Each unread message is handed to Action Mailbox,
# which routes it like mail from an ingress, and is then deleted from the
# mailbox (or only marked read when RECEIPT_INBOX_IMAP_KEEP is set).
#
# Overlapping runs are harmless: Action Mailbox refuses a message it already
# holds (same Message-ID and checksum).
class Receipt::ImapFetcher
  MAX_MESSAGES_PER_RUN = 50
  # Ten attachments of at most 10 MB each, base64-encoded.
  MAX_MESSAGE_BYTES = 150.megabytes
  TIMEOUT = 30

  class << self
    def configured?
      Receipt::EmailInbox.configured? && settings.values_at(:host, :username, :password).all?(&:present?)
    end

    def settings
      {
        host: ENV["RECEIPT_INBOX_IMAP_HOST"].presence,
        port: ENV.fetch("RECEIPT_INBOX_IMAP_PORT", 993).to_i,
        username: ENV["RECEIPT_INBOX_IMAP_USERNAME"].presence,
        password: ENV["RECEIPT_INBOX_IMAP_PASSWORD"].presence,
        mailbox: ENV["RECEIPT_INBOX_IMAP_MAILBOX"].presence || "INBOX",
        ssl: ENV.fetch("RECEIPT_INBOX_IMAP_SSL", "true") != "false",
        keep: ENV["RECEIPT_INBOX_IMAP_KEEP"] == "true"
      }
    end
  end

  def initialize(settings = self.class.settings)
    @settings = settings
  end

  # Returns how many messages were handed to Action Mailbox.
  def fetch
    imap = connect
    imap.select(settings[:mailbox])
    uids = imap.uid_search([ "UNSEEN" ]).to_a.first(MAX_MESSAGES_PER_RUN)
    received = uids.count { |uid| receive(imap, uid) }
    imap.expunge unless settings[:keep] || received.zero?
    received
  rescue Net::IMAP::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error => e
    DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt IMAP fetch failed: #{e.class}",
                          source: "receipt_imap")
    0
  ensure
    disconnect(imap)
  end

  private
    attr_reader :settings

    def connect
      imap = Net::IMAP.new(settings[:host], port: settings[:port], ssl: settings[:ssl] ? { verify_mode: OpenSSL::SSL::VERIFY_PEER } : false,
                                            open_timeout: TIMEOUT, idle_response_timeout: TIMEOUT)
      imap.login(settings[:username], settings[:password])
      imap
    end

    def receive(imap, uid)
      size = imap.uid_fetch(uid, "RFC822.SIZE")&.first&.attr&.dig("RFC822.SIZE").to_i
      if size <= 0 || size > MAX_MESSAGE_BYTES
        DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt IMAP message skipped: size #{size}",
                              source: "receipt_imap")
        mark_done(imap, uid, delete: false)
        return false
      end

      source = imap.uid_fetch(uid, "BODY.PEEK[]")&.first&.attr&.dig("BODY[]")
      return false if source.blank?

      ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
      mark_done(imap, uid, delete: !settings[:keep])
      true
    rescue ActiveRecord::ActiveRecordError, ActiveStorage::Error => e
      # Left unread, the message is tried again on the next run.
      DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt IMAP message not stored: #{e.class}",
                            source: "receipt_imap")
      false
    end

    def mark_done(imap, uid, delete:)
      imap.uid_store(uid, "+FLAGS", delete ? [ :Seen, :Deleted ] : [ :Seen ])
    end

    def disconnect(imap)
      return if imap.nil? || imap.disconnected?

      imap.logout
      imap.disconnect
    rescue Net::IMAP::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end
end
