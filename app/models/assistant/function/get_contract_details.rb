class Assistant::Function::GetContractDetails < Assistant::Function
  include Assistant::Function::ContractsSupport

  class << self
    def name
      "get_contract_details"
    end

    def description
      <<~INSTRUCTIONS
        Get one contract in full: terms, notice deadline, the bills linked to it (with
        their price history), document names and contact availability.

        contract_id must be the exact id returned by get_contracts. Contract and customer
        numbers, phone numbers and the people insured are never returned.
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

    contract, error = find_contract(params["contract_id"])
    return error if error

    bills = contract.visible_recurring_transactions_for(user).includes(:merchant, :recurring_price_changes).to_a

    {
      contract: serialize_contract(contract),
      bills: bills.map { |bill| serialize_bill(bill) },
      further_bills_not_visible: contract.hidden_recurring_transactions_for?(user),
      documents: contract.contract_documents.with_attached_file.map { |document| document.file.filename.to_s },
      document_links: contract.document_links.map { |link| link["label"].presence || "link" },
      has_customer_portal: contract.portal_url.present?,
      has_service_phone: contract.service_phone.present?,
      has_claims_hotline: contract.claims_phone.present?,
      # Notes are left out: they are free text and may well hold a number.
      successor: contract.replaced_by&.then { |successor| successor.viewable_by?(user) ? successor.name : nil }
    }.compact
  end

  private
    def serialize_bill(bill)
      {
        id: bill.id,
        name: bill.display_name,
        amount: bill.amount.abs.to_f,
        currency: bill.currency,
        status: bill.status,
        next_expected_date: bill.next_expected_date&.iso8601,
        price_changes: bill.recent_price_changes(5).map do |change|
          { effective_on: change.effective_on.iso8601, previous_amount: change.previous_amount.abs.to_f, new_amount: change.new_amount.abs.to_f }
        end
      }
    end
end
