# Builds receipt e-mails for the e-mail inbox tests.
module ReceiptMailHelper
  RECEIPT_INBOX_ENV = { "RECEIPT_INBOX_ADDRESS" => "receipts@mail.example.com" }.freeze

  def with_receipt_inbox(overrides = {}, &block)
    with_env_overrides(RECEIPT_INBOX_ENV.merge(overrides), &block)
  end

  def receipt_mail(to:, from:, attachments: {}, headers: {})
    mail = Mail.new
    mail.from = from
    mail.to = to if to
    mail.subject = "Invoice"
    mail.message_id = "<#{SecureRandom.hex(8)}@example.com>"
    headers.each { |name, value| mail[name] = value }
    mail.text_part = Mail::Part.new(body: "Your invoice is attached.")
    attachments.each { |filename, content| mail.attachments[filename] = content }
    mail
  end

  def enable_receipt_preview!(user)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
  end
end
