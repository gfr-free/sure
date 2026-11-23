# Mail to any other address is dropped quietly.
class UnroutedMailbox < ApplicationMailbox
  def process
    bounced!
  end
end
