# frozen_string_literal: true

require "net/imap"

# Collects receipt mail from an IMAP mailbox the operator names, for setups
# without a public mail ingress. Each unread message is handed to Action Mailbox,
# which routes it like mail from an ingress, and is then deleted from the
# mailbox (or only marked read when RECEIPT_INBOX_IMAP_KEEP is set).
#
# In delete mode a message is never marked read, so a run that breaks off before
# the expunge leaves it for the next one, which finds it already stored and only
# makes sure it was routed.
class Receipt::ImapFetcher
  MAX_MESSAGES_PER_RUN = 50
  # Ten attachments of at most 10 MB each, base64-encoded.
  MAX_MESSAGE_BYTES = 150.megabytes
  TIMEOUT = 30
  # Net::IMAP has no read timeout outside IDLE, so a server that stops
  # answering would otherwise hold a worker thread for good.
  RUN_DEADLINE = 4.minutes

  class << self
    def configured?
      Receipt::EmailInbox.configured? && credentials_present?
    end

    def credentials_present?
      settings.values_at(:host, :username, :password).all?(&:present?)
    end

    def settings
      {
        host: ENV["RECEIPT_INBOX_IMAP_HOST"].presence,
        port: ENV["RECEIPT_INBOX_IMAP_PORT"].presence&.to_i || 993,
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
    imap = nil
    Timeout.timeout(RUN_DEADLINE) do
      imap = connect
      imap.select(settings[:mailbox])
      uids = imap.uid_search([ "UNSEEN" ]).to_a.first(MAX_MESSAGES_PER_RUN)
      received = uids.select { |uid| receive(imap, uid) }
      delete(imap, received) unless settings[:keep] || received.empty?
      received.size
    end
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
      begin
        imap.login(settings[:username], settings[:password])
      rescue StandardError
        # A refused login leaves the connection open, and fetch never sees it.
        disconnect(imap)
        raise
      end
      imap
    end

    def receive(imap, uid)
      size = imap.uid_fetch(uid, "RFC822.SIZE")&.first&.attr&.dig("RFC822.SIZE").to_i
      if size <= 0 || size > MAX_MESSAGE_BYTES
        set_aside(imap, uid, "size #{size}")
        return false
      end

      source = imap.uid_fetch(uid, "BODY.PEEK[]")&.first&.attr&.dig("BODY[]")
      if source.blank?
        set_aside(imap, uid, "empty body")
        return false
      end

      store(source)
      mark_seen(imap, uid) if settings[:keep]
      true
    rescue Net::IMAP::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error
      raise
    rescue StandardError => e
      # Storage or database trouble is usually brief: left unread, the message is
      # tried again on the next run, and the rest of this run goes on.
      DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt IMAP message not stored: #{e.class}",
                            source: "receipt_imap")
      false
    end

    # Marked read but kept, so it is not fetched again and the operator can look.
    def set_aside(imap, uid, reason)
      DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt IMAP message skipped: #{reason}",
                            source: "receipt_imap")
      mark_seen(imap, uid)
    end

    # A message stored by an earlier, interrupted run is not stored again, which
    # would leave its raw mail behind unattached. If that run could not queue
    # the routing, it is queued now; a failure here leaves the message unread.
    # The lock keeps two overlapping runs from storing the same message at once.
    def store(source)
      checksum = OpenSSL::Digest::SHA1.hexdigest(source)
      existing = ActionMailbox::InboundEmail.transaction do
        ActionMailbox::InboundEmail.connection.execute(
          ActionMailbox::InboundEmail.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "receipt_imap:#{checksum}" ])
        )
        ActionMailbox::InboundEmail.find_by(message_checksum: checksum).tap do |found|
          ActionMailbox::InboundEmail.create_and_extract_message_id!(source) if found.nil?
        end
      end
      existing.route_later if existing&.pending?
    end

    # Removes only this run's messages where the server can (UIDPLUS); otherwise
    # every message flagged deleted goes, which is why the mailbox should serve
    # receipts only.
    # Not marked read, so a failed expunge leaves the messages for the next run,
    # which finds them already stored.
    def delete(imap, uids)
      imap.uid_store(uids, "+FLAGS", [ :Deleted ])
      if imap.capability.include?("UIDPLUS")
        imap.uid_expunge(uids)
      else
        imap.expunge
      end
    end

    def mark_seen(imap, uid)
      imap.uid_store(uid, "+FLAGS", [ :Seen ])
    end

    def disconnect(imap)
      return if imap.nil? || imap.disconnected?

      begin
        Timeout.timeout(TIMEOUT) { imap.logout }
      rescue Net::IMAP::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error
        nil
      end
      imap.disconnect unless imap.disconnected?
    rescue Net::IMAP::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end
end
