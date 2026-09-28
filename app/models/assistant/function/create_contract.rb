class Assistant::Function::CreateContract < Assistant::Function
  include Assistant::Function::ContractsSupport

  class << self
    def name
      "create_contract"
    end

    def description
      <<~INSTRUCTIONS
        Record a new contract owned by the user. Only name, provider and kind are
        required; pass the terms the user states. Contract and customer numbers cannot be
        set here; tell the user to add them on the contract page.

        bill_ids links existing bills (ids from get_bills) that pay for the contract; the
        yearly cost comes from them. Confirm the details with the user before calling.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[name provider kind],
      properties: contract_properties.merge(
        bill_ids: { type: "array", items: { type: "string" }, description: "Bills that pay for this contract, ids from get_bills." }
      )
    )
  end

  def call(params = {})
    return contracts_disabled_result if contracts_disabled?

    contract = family.contracts.new(owner: user)
    assign_contract_attributes(contract, params)

    unless contract.save
      return { error: contract.errors.full_messages.to_sentence, hint: "Fix the listed fields and try again." }
    end

    linked = link_bills(contract, params["bill_ids"])
    { contract: serialize_contract(contract.reload), linked_bills: linked, url: Rails.application.routes.url_helpers.contract_path(contract) }
  end

  private
    def contract_properties
      {
        name: { type: "string" },
        provider: { type: "string", description: "The company the contract is with." },
        kind: { type: "string", enum: Contract.kinds.keys },
        started_on: { type: "string", description: "YYYY-MM-DD" },
        minimum_term_months: { type: "integer", minimum: 0 },
        notice_period_value: { type: "integer", minimum: 0 },
        notice_period_unit: { type: "string", enum: Contract.notice_period_units.keys },
        notice_anchor: { type: "string", enum: Contract.notice_anchors.keys, description: "end_of_term, end_of_month or any_day." },
        renewal_period_months: { type: "integer", minimum: 1, description: "Leave out when it runs on indefinitely after the minimum term." },
        renewal_anchor_on: { type: "string", description: "Main due date, YYYY-MM-DD." },
        ends_on: { type: "string", description: "Fixed end date, YYYY-MM-DD." }
      }
    end

    def assign_contract_attributes(contract, params)
      contract.name = params["name"] if params.key?("name")
      contract.provider_name = params["provider"] if params.key?("provider")
      contract.kind = params["kind"] if params["kind"].in?(Contract.kinds.keys)
      %w[minimum_term_months notice_period_value renewal_period_months].each do |key|
        contract.public_send("#{key}=", params[key]) if params.key?(key)
      end
      contract.notice_period_unit = params["notice_period_unit"] if params["notice_period_unit"].in?(Contract.notice_period_units.keys)
      contract.notice_anchor = params["notice_anchor"] if params["notice_anchor"].in?(Contract.notice_anchors.keys)
      %w[started_on renewal_anchor_on ends_on].each do |key|
        next unless params.key?(key)

        contract.public_send("#{key}=", parse_date(params[key]))
      end
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    # Only bills this user may change, as on the contract form.
    def link_bills(contract, bill_ids)
      ids = Array(bill_ids).select { |id| valid_uuid?(id) }
      return [] if ids.empty?

      writable = RecurringTransaction.where(account_id: nil)
                                     .or(RecurringTransaction.where(account_id: Account.writable_by(user).select(:id)))
      bills = family.recurring_transactions.accessible_by(user).and(writable).where(id: ids).to_a
      bills.each { |bill| bill.update!(contract: contract) }
      bills.map(&:display_name)
    end
end
