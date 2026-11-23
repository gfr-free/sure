class ApplicationMailbox < ActionMailbox::Base
  routing ->(inbound_email) { Receipt::EmailInbox.addressed_to_inbox?(inbound_email.mail) } => :receipts
  routing all: :unrouted
end
