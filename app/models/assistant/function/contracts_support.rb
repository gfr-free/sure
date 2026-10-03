# frozen_string_literal: true

# Shared plumbing for the contract tools. Contracts sit behind the Bills gates
# and are visible to their owner and the members they are shared with; tool
# calls never pass through the controllers, so every tool re-checks both.
#
# Contract and customer numbers never appear in a tool result: Sure sends
# nothing through a redaction layer before an LLM call, so leaving them out is
# the only protection. Personal details (phone number, meter number, insured
# persons, beneficiaries) stay out for the same reason.
module Assistant::Function::ContractsSupport
  SAFE_DETAIL_KEYS = %w[
    insurance_line sum_insured deductible tariff data_volume_gb device_paid_off_on
    bandwidth_mbit advance_payment price_guarantee_until deposit operating_costs_advance plan
  ].freeze

  private
    def contracts_disabled?
      family.recurring_transactions_disabled?
    end

    def contracts_disabled_result
      {
        error: "Contracts are part of Bills, which is disabled for this family",
        hint: "Do not retry. Tell the user Bills & recurring transactions are switched off under Settings -> Recurring transactions."
      }
    end

    def accessible_contracts
      family.contracts.accessible_by(user)
    end

    # Returns [contract, nil], or [nil, error_hash] for a malformed UUID.
    # Raises ActiveRecord::RecordNotFound for missing or inaccessible contracts.
    def find_contract(id)
      unless valid_uuid?(id)
        return [ nil, {
          error: "contract_id is not a valid id",
          hint: "Pass the exact id returned by get_contracts."
        } ]
      end

      [ accessible_contracts.find(id), nil ]
    end

    # Uses find_contract's result/error contract, also returning [nil, error_hash]
    # for read-only access. Missing or inaccessible records still raise
    # ActiveRecord::RecordNotFound.
    def find_editable_contract(id)
      contract, error = find_contract(id)
      return [ nil, error ] if error

      unless contract.editable_by?(user)
        return [ nil, {
          error: "#{contract.name} is shared with you read-only",
          hint: "You can read this contract but not change it. Do not retry."
        } ]
      end

      [ contract, nil ]
    end

    # Returns terms, permissions and visible annual cost, omitting nil fields,
    # contract/customer numbers and notes, and restricting details to SAFE_DETAIL_KEYS.
    # cost may supply the [money_or_nil, unconvertible_count] from annual_cost_for.
    def serialize_contract(contract, cost: nil)
      schedule = contract.notice_schedule
      money, unconvertible = cost || contract.annual_cost_for(user)

      {
        id: contract.id,
        name: contract.name,
        kind: contract.kind,
        provider: contract.provider_display_name,
        status: contract.display_status,
        owned_by_you: contract.owner_id == user.id,
        your_permission: contract.permission_for(user).to_s,
        started_on: contract.started_on&.iso8601,
        minimum_term_months: contract.minimum_term_months,
        notice_period: notice_period(contract),
        no_notice_needed: contract.notice_not_required? || nil,
        renewal_period_months: contract.renewal_period_months,
        ends_on: contract.ends_on&.iso8601,
        notice_deadline: schedule.notice_deadline&.iso8601,
        term_ends_on: schedule.term_ends_on&.iso8601,
        earliest_end_if_cancelled_today: schedule.earliest_end_on&.iso8601,
        annual_cost: money && { amount: money.amount.round(money.currency.default_precision).to_f, currency: money.currency.iso_code },
        annual_cost_unconvertible_bills: unconvertible.to_i.positive? ? unconvertible : nil,
        related_account: contract.account_id && Account.accessible_by(user).where(id: contract.account_id).pick(:name),
        details: contract.details.to_h.slice(*SAFE_DETAIL_KEYS).presence
      }.compact
    end

    def notice_period(contract)
      return if contract.notice_period_value.nil?

      { value: contract.notice_period_value, unit: contract.notice_period_unit, to: contract.notice_anchor }.compact
    end
end
