class Assistant::Function::UpdateContract < Assistant::Function::CreateContract
  class << self
    def name
      "update_contract"
    end

    def description
      <<~INSTRUCTIONS
        Change a contract's name, provider, kind or terms. Only pass the fields being
        changed. Numbers cannot be set here. Ending a contract, sharing and
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

  # Updates supplied fields and adds bill links, returning the serialized contract
  # and linked bill names. Disabled Bills, malformed IDs/dates, read-only access and
  # contract or bill validation failures return error hashes; a failure saves
  # nothing. Missing or inaccessible records raise ActiveRecord::RecordNotFound.
  def call(params = {})
    return contracts_disabled_result if contracts_disabled?

    contract, error = find_editable_contract(params["contract_id"])
    return error if error

    invalid_dates = assign_contract_attributes(contract, params)
    return invalid_dates_result(invalid_dates) if invalid_dates.any?

    linked, error = save_and_link_bills(contract, params["bill_ids"])
    return error if error

    { contract: serialize_contract(contract.reload), linked_bills: linked }
  end
end
