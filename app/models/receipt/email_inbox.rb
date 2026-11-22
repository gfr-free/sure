# frozen_string_literal: true

# Turns e-mails into receipts. Each user can switch on a private address of the
# form `<local>+<token>@<domain>`, built from the operator's RECEIPT_INBOX_ADDRESS.
# Mail reaches Sure through Action Mailbox, either from a mail service ingress or
# from the IMAP poller (Receipt::ImapFetcher), and the token picks the user.
#
# The token is the secret; the sender check is a second hurdle, not proof of
# identity, because a From header can be forged. Only the attachments are kept,
# never the mail text.
class Receipt::EmailInbox
  TOKEN_LENGTH = 24
  MAX_ATTACHMENTS = 10
  MAX_EXTRA_SENDERS = 10
  # Smaller images are almost always logos or signatures embedded in the mail.
  MIN_IMAGE_BYTES = 10.kilobytes
  ADDRESS_FORMAT = /\A[a-z0-9._-]+@[a-z0-9.-]+\.[a-z]{2,}\z/

  Result = Data.define(:created, :duplicates, :skipped)

  class << self
    # The operator's base address, e.g. "receipts@mail.example.com". Without it
    # the feature stays hidden.
    def base_address
      address = ENV["RECEIPT_INBOX_ADDRESS"].to_s.strip.downcase
      address if address.match?(ADDRESS_FORMAT) && !address.include?("+")
    end

    def configured?
      base_address.present?
    end

    def address_for(user)
      return nil unless configured? && user.receipt_inbox_token.present?

      local, domain = base_address.split("@", 2)
      "#{local}+#{user.receipt_inbox_token}@#{domain}"
    end

    # Switching on again, or rotating, makes the old address stop working.
    def enable!(user)
      user.update!(receipt_inbox_token: SecureRandom.base36(TOKEN_LENGTH))
    end

    def disable!(user)
      user.update!(receipt_inbox_token: nil)
    end

    def update_senders!(user, text)
      senders = text.to_s.split(/[\s,;]+/).map { |address| address.strip.downcase }.compact_blank.uniq
      invalid = senders.reject { |address| address.match?(ADDRESS_FORMAT) }
      if invalid.any? || senders.size > MAX_EXTRA_SENDERS
        user.errors.add(:receipt_inbox_senders, :invalid, count: MAX_EXTRA_SENDERS)
        raise ActiveRecord::RecordInvalid, user
      end

      user.update!(receipt_inbox_senders: (senders - [ user.email.to_s.downcase ]).join("\n").presence)
    end

    # Stored as one address per line, so the column can be encrypted.
    def extra_senders(user)
      user.receipt_inbox_senders.to_s.split("\n")
    end

    def addressed_to_inbox?(mail)
      token_from(mail).present?
    end

    # The user whose address the mail was sent to, if that user may receive it.
    def recipient_user(mail)
      token = token_from(mail)
      return nil if token.blank?

      user = User.find_by(receipt_inbox_token: token)
      user if user&.active? && Receipt.manager?(user) && user.preview_features_enabled?
    end

    def allowed_sender?(user, mail)
      senders = Array(mail.from).map { |address| address.to_s.strip.downcase }.uniq
      return false unless senders.size == 1

      [ user.email.to_s.downcase, *extra_senders(user) ].include?(senders.first)
    end

    # Creates a receipt for each usable attachment. Returns nil when the mail is
    # refused as a whole.
    def receive(mail)
      user = recipient_user(mail)
      return nil if user.nil?

      unless allowed_sender?(user, mail)
        DebugLogEntry.capture(category: "receipts", level: "warn", message: "Receipt e-mail refused: sender not allowed",
                              source: "receipt_email", family: user.family, user_id: user.id)
        return nil
      end

      receive_attachments(user, mail)
    end

    private
      def token_from(mail)
        return nil unless configured?

        local, domain = base_address.split("@", 2)
        pattern = /(?:\A|[\s<,"])#{Regexp.escape(local)}\+([a-z0-9]{#{TOKEN_LENGTH}})@#{Regexp.escape(domain)}(?:\z|[\s>,"])/i
        recipient_strings(mail).each do |value|
          match = value.match(pattern)
          return match[1].downcase if match
        end
        nil
      end

      # Plus-addressed mail fetched over IMAP often keeps the real recipient only
      # in Delivered-To, for example when it arrived as a Bcc.
      def recipient_strings(mail)
        addresses = Array(mail.to) + Array(mail.cc) + Array(mail.bcc)
        headers = mail.header.fields.select { |field| field.name.to_s.downcase.in?(%w[delivered-to x-original-to x-forwarded-to]) }
        (addresses + headers.map(&:value)).map(&:to_s)
      end

      def receive_attachments(user, mail)
        created = 0
        duplicates = 0
        skipped = 0

        usable = mail.attachments.reject { |part| logo?(part) }
        skipped += mail.attachments.size - usable.size

        usable.each_with_index do |part, index|
          if index >= MAX_ATTACHMENTS
            skipped += 1
            next
          end

          Receipt.create_from_content!(
            family: user.family,
            user: user,
            content: part.decoded.to_s.b,
            filename: part.filename.to_s,
            source: "email"
          )
          created += 1
        rescue Receipt::DuplicateUploadError
          duplicates += 1
        rescue Receipt::InvalidUploadError, ActiveRecord::RecordInvalid
          skipped += 1
        end

        Result.new(created:, duplicates:, skipped:)
      end

      def logo?(part)
        part.mime_type.to_s.start_with?("image/") && part.decoded.to_s.bytesize < MIN_IMAGE_BYTES
      end
  end
end
