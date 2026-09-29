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

  # Saves a contract owned by the user, then links writable bills. Returns the
  # serialized contract, linked bill names and path, or an error hash for disabled
  # Bills, malformed dates or contract validation failures. Bill validation failures
  # raise ActiveRecord::RecordInvalid after the contract has already been saved.
  def call(params = {})
    return contracts_disabled_result if contracts_disabled?

    contract = family.contracts.new(owner: user)
    invalid_dates = assign_contract_attributes(contract, params)
    return invalid_dates_result(invalid_dates) if invalid_dates.any?

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

    # Returns the date params that were present but unparseable. Those calls
    # are rejected outright: assigning nil instead would silently clear a
    # stored date over a malformed LLM value.
    def assign_contract_attributes(contract, params)
      contract.name = params["name"] if params.key?("name")
      contract.provider_name = params["provider"] if params.key?("provider")
      contract.kind = params["kind"] if params["kind"].in?(Contract.kinds.keys)
      %w[minimum_term_months notice_period_value renewal_period_months].each do |key|
        contract.public_send("#{key}=", params[key]) if params.key?(key)
      end
      contract.notice_period_unit = params["notice_period_unit"] if params["notice_period_unit"].in?(Contract.notice_period_units.keys)
      contract.notice_anchor = params["notice_anchor"] if params["notice_anchor"].in?(Contract.notice_anchors.keys)

      %w[started_on renewal_anchor_on ends_on].filter_map do |key|
        next unless params.key?(key)

        if params[key].blank?
          contract.public_send("#{key}=", nil)
          next
        end

        date = parse_date(params[key])
        next key if date.nil?

        contract.public_send("#{key}=", date)
        nil
      end
    end

    def invalid_dates_result(keys)
      {
        error: "#{keys.join(', ')} is not a valid date",
        hint: "Pass dates as YYYY-MM-DD, or an empty string to clear a date. Nothing was changed."
      }
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    # Links visible bills the user may change and returns their display names.
    # Invalid, missing or inaccessible IDs are ignored, and so are bills held by
    # a contract the user cannot edit; other existing contract links on selected
    # bills are replaced. ActiveRecord::RecordInvalid propagates,
    # leaving earlier bill updates saved unless the caller supplies a transaction.
    def link_bills(contract, bill_ids)
      ids = Array(bill_ids).select { |id| valid_uuid?(id) }
      return [] if ids.empty?

      bills = family.recurring_transactions.linkable_by(user).where(id: ids).to_a
      bills.each { |bill| bill.update!(contract: contract) }
      bills.map(&:display_name)
    end
end
