# Mail to a user's receipt address. Refused mail is marked bounced without a
# reply, so a forged sender never gets mail back from Sure.
class ReceiptsMailbox < ApplicationMailbox
  def process
    bounced! if Receipt::EmailInbox.receive(mail).nil?
  end
end
