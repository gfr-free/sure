class Assistant::Function::GetContracts < Assistant::Function
  include Assistant::Function::ContractsSupport

  class << self
    def name
      "get_contracts"
    end

    def description
      <<~INSTRUCTIONS
        List the user's contracts: insurance, mobile phone, internet, energy, streaming,
        software, fitness, memberships and rent. Each contract carries its terms, notice
        deadline, yearly cost (from the bills linked to it) and status.

        notice_deadline is the last day notice can be given for the contract to end on
        term_ends_on; it is null when the contract can be cancelled at any time, is
        already cancelled, or its terms are not recorded. Contract and customer numbers
        are never available to you; do not ask for them.

        Use this for questions like "which contracts can I cancel this month?", "what
        do my insurances cost per year?" or "when does my phone contract end?".
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        kind: { type: "string", enum: Contract.kinds.keys, description: "Only contracts of this kind." },
        status: { type: "string", enum: %w[open active cancellation_sent cancelled ended], description: "open = everything not ended (default)." }
      }
    )
  end

  def call(params = {})
    return contracts_disabled_result if contracts_disabled?

    contracts = accessible_contracts.includes(:merchant, :account, :contract_shares).alphabetically.to_a
    contracts = contracts.select { |contract| contract.kind == params["kind"] } if params["kind"].present?

    status = params["status"].presence || "open"
    contracts = if status == "open"
      contracts.select(&:open?)
    else
      contracts.select { |contract| contract.display_status == status }
    end

    costs = Contract.annual_costs_for(contracts, user)

    {
      as_of: Date.current.iso8601,
      currency: family.currency,
      contracts: contracts.map { |contract| serialize_contract(contract, cost: costs[contract.id]) }
    }
  end
end
