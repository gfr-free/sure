# Notice-deadline and price-guarantee reminders, sent to the contract's owner
# only: a contract is private to its owner and shares, and the owner is the one
# who manages it.
# Contract and customer numbers are left out of the email.
class ContractMailer < ApplicationMailer
  def notice_reminder(contract:, deadline:, term_ends_on:)
    @contract = contract
    @recipient = contract.owner
    @deadline = deadline
    @term_ends_on = term_ends_on
    # The family's date, not the server's: the job decides stages on it too.
    @days_left = (deadline - contract.family.current_date).to_i
    @contract_url = contract_url(contract)

    I18n.with_locale(@recipient.locale.presence || contract.family.locale.presence || I18n.default_locale) do
      mail(
        to: @recipient.email,
        subject: t(".subject", name: contract.name, date: I18n.l(deadline, format: :long))
      )
    end
  end

  def price_guarantee_reminder(contract:, guarantee_until:)
    @contract = contract
    @recipient = contract.owner
    @guarantee_until = guarantee_until
    @days_left = (guarantee_until - contract.family.current_date).to_i
    @contract_url = contract_url(contract)

    I18n.with_locale(@recipient.locale.presence || contract.family.locale.presence || I18n.default_locale) do
      mail(
        to: @recipient.email,
        subject: t(".subject", name: contract.name, date: I18n.l(guarantee_until, format: :long))
      )
    end
  end
end
