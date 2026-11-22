# Action Mailbox uploads the raw mail before it inserts the inbound e-mail, and
# a duplicate delivery is rejected only at the insert. The upload of a rejected
# duplicate is left without a record, so incineration never reaches it.
class PurgeOrphanedInboundMailJob < ApplicationJob
  queue_as :scheduled

  GRACE_PERIOD = 1.day

  def perform
    return unless Receipt::EmailInbox.configured?

    ActiveStorage::Blob.unattached
      .where(filename: "message.eml", content_type: "message/rfc822", service_name: ActionMailbox.storage_service || ActiveStorage::Blob.service.name)
      .where(created_at: ...GRACE_PERIOD.ago)
      .find_each(&:purge)
  end
end
