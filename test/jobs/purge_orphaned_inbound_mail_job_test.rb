require "test_helper"

class PurgeOrphanedInboundMailJobTest < ActiveJob::TestCase
  include ReceiptMailHelper

  test "purges only old raw mail that no inbound e-mail holds" do
    orphan = raw_mail_blob(created_at: 2.days.ago)
    recent = raw_mail_blob(created_at: 1.hour.ago)
    other = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "notes.txt", content_type: "text/plain")
    other.update_column(:created_at, 2.days.ago)
    kept = ActionMailbox::InboundEmail.create_and_extract_message_id!(receipt_mail(to: "receipts+#{'a' * 24}@mail.example.com", from: "a@example.com").to_s)
    kept.raw_email.blob.update_column(:created_at, 2.days.ago)

    with_receipt_inbox { PurgeOrphanedInboundMailJob.perform_now }

    assert_not ActiveStorage::Blob.exists?(orphan.id)
    assert ActiveStorage::Blob.exists?(recent.id)
    assert ActiveStorage::Blob.exists?(other.id)
    assert kept.reload.raw_email.attached?
  end

  test "does nothing while the receipt inbox is off" do
    orphan = raw_mail_blob(created_at: 2.days.ago)

    PurgeOrphanedInboundMailJob.perform_now

    assert ActiveStorage::Blob.exists?(orphan.id)
  end

  private
    def raw_mail_blob(created_at:)
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new("Subject: x\r\n\r\nbody"), filename: "message.eml", content_type: "message/rfc822").tap do |blob|
        blob.update_column(:created_at, created_at)
      end
    end
end
