# Notice-deadline reminders, sent to the contract's owner only: a contract is
# private to its owner and shares, and the owner is the one who manages it.
# Contract and customer numbers are left out of the email.
class ContractMailer < ApplicationMailer
  def notice_reminder(contract:, deadline:, term_ends_on:)
    @contract = contract
    @recipient = contract.owner
    @deadline = deadline
    @term_ends_on = term_ends_on
    @days_left = (deadline - Date.current).to_i
    @contract_url = contract_url(contract)

    I18n.with_locale(@recipient.locale.presence || contract.family.locale.presence || I18n.default_locale) do
      mail(
        to: @recipient.email,
        subject: t(".subject", name: contract.name, date: I18n.l(deadline, format: :long))
      )
    end
  end
end
