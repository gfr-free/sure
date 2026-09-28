class Assistant::Function::UpdateContract < Assistant::Function::CreateContract
  class << self
    def name
      "update_contract"
    end

    def description
      <<~INSTRUCTIONS
        Change a contract's name, provider, kind or terms. Only pass the fields being
        changed. Numbers cannot be set here. Recording a cancellation, sharing and
        deleting stay in the app. Confirm the change with the user before calling.

        contract_id must be the exact id returned by get_contracts.
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: %w[contract_id],
      properties: { contract_id: { type: "string" } }.merge(contract_properties).merge(
        bill_ids: { type: "array", items: { type: "string" }, description: "Bills to link additionally, ids from get_bills." }
      )
    )
  end

  def call(params = {})
    return contracts_disabled_result if contracts_disabled?

    contract, error = find_editable_contract(params["contract_id"])
    return error if error

    assign_contract_attributes(contract, params)

    unless contract.save
      return { error: contract.errors.full_messages.to_sentence, hint: "Fix the listed fields and try again." }
    end

    linked = link_bills(contract, params["bill_ids"])
    { contract: serialize_contract(contract.reload), linked_bills: linked }
  end
end
