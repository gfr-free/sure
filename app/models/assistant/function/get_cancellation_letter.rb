class Assistant::Function::GetCancellationLetter < Assistant::Function
  include Assistant::Function::ContractsSupport

  class << self
    def name
      "get_cancellation_letter"
    end

    def description
      <<~INSTRUCTIONS
        Get a link to a ready-to-send cancellation letter for a contract. Sure fills in
        the contract and customer numbers itself, so you never see them: do not write the
        letter yourself and do not ask the user for the numbers. Give the user the link;
        they review, print or copy it and send it. Sure never sends anything to the
        provider. Also mention the notice deadline if one is returned.
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: [ "contract_id" ],
      properties: {
        contract_id: { type: "string", description: "The contract's id, exactly as returned by get_contracts." }
      }
    )
  end

  def call(params = {})
    return contracts_disabled_result if contracts_disabled?

    contract, error = find_editable_contract(params["contract_id"])
    return error if error

    schedule = contract.notice_schedule

    {
      contract: contract.name,
      url: Rails.application.routes.url_helpers.cancellation_letter_contract_path(contract),
      notice_deadline: schedule.notice_deadline&.iso8601,
      ends_on_if_sent_today: (schedule.notice_deadline ? schedule.term_ends_on : schedule.earliest_end_on)&.iso8601
    }.compact
  end
end
