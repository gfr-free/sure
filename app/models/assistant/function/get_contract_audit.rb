class Assistant::Function::GetContractAudit < Assistant::Function
  include Assistant::Function::ContractsSupport

  DEADLINE_WINDOW_DAYS = 90
  PRICE_WINDOW_DAYS = 365

  class << self
    def name
      "get_contract_audit"
    end

    def description
      <<~INSTRUCTIONS
        Review the user's contracts for things to act on:
        - upcoming_deadlines: notice deadlines in the next #{DEADLINE_WINDOW_DAYS} days
        - price_increases: linked bills that got more expensive in the last year; for
          insurance, telecoms and energy a price increase often opens a special right to
          cancel (special_termination_likely)
        - possible_duplicates: several contracts of the same kind with the same provider
        - overlapping_subscriptions: more than one open streaming contract
        - without_payments: open contracts with no linked bill, so their cost is unknown
        - charges_after_end: payments made after a contract's end date

        Present findings as suggestions; never state that a special termination right
        definitely applies, and never give legal or tax advice.
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema
  end

  def call(_params = {})
    return contracts_disabled_result if contracts_disabled?

    contracts = accessible_contracts.includes(:merchant).to_a
    open = contracts.select(&:open?)
    today = Date.current

    {
      as_of: today.iso8601,
      upcoming_deadlines: upcoming_deadlines(open, today),
      price_increases: price_increases(open, today),
      possible_duplicates: possible_duplicates(open),
      overlapping_subscriptions: overlapping_subscriptions(open),
      without_payments: without_payments(open),
      charges_after_end: charges_after_end(contracts, today)
    }
  end

  private
    def upcoming_deadlines(contracts, today)
      contracts.filter_map do |contract|
        schedule = contract.notice_schedule(today: today)
        next unless schedule.notice_deadline && schedule.notice_deadline <= today + DEADLINE_WINDOW_DAYS

        { id: contract.id, name: contract.name, kind: contract.kind,
          notice_deadline: schedule.notice_deadline.iso8601, term_ends_on: schedule.term_ends_on&.iso8601 }
      end.sort_by { |row| row[:notice_deadline] }
    end

    def price_increases(contracts, today)
      by_id = contracts.index_by(&:id)
      RecurringPriceChange.joins(:recurring_transaction)
                          .merge(RecurringTransaction.accessible_by(user))
                          .where(recurring_transactions: { contract_id: by_id.keys })
                          .where(effective_on: (today - PRICE_WINDOW_DAYS)..today)
                          .includes(:recurring_transaction)
                          .select { |change| change.new_amount.abs > change.previous_amount.abs }
                          .map do |change|
        contract = by_id.fetch(change.recurring_transaction.contract_id)
        { id: contract.id, name: contract.name, kind: contract.kind,
          effective_on: change.effective_on.iso8601,
          previous_amount: change.previous_amount.abs.to_f, new_amount: change.new_amount.abs.to_f, currency: change.currency,
          special_termination_likely: contract.kind.in?(Insight::Generators::ContractGenerator::SPECIAL_TERMINATION_KINDS) }
      end
    end

    def possible_duplicates(contracts)
      contracts.group_by { |contract| [ contract.kind, contract.provider_display_name.to_s.downcase ] }
               .values
               .select { |group| group.size > 1 }
               .map { |group| group.map { |contract| { id: contract.id, name: contract.name } } }
    end

    def overlapping_subscriptions(contracts)
      streaming = contracts.select(&:streaming?)
      return [] if streaming.size < 2

      streaming.map { |contract| { id: contract.id, name: contract.name, provider: contract.provider_display_name } }
    end

    def without_payments(contracts)
      costs = Contract.annual_costs_for(contracts, user)
      contracts.select { |contract| costs.dig(contract.id, 0).nil? }.map { |contract| { id: contract.id, name: contract.name } }
    end

    def charges_after_end(contracts, today)
      contracts.select { |contract| contract.ends_on.present? && contract.ends_on < today }.filter_map do |contract|
        count = RecurringAllocation.confirmed
                                   .joins(:entry, recurring_occurrence: :recurring_transaction)
                                   .merge(RecurringTransaction.accessible_by(user))
                                   .where(recurring_transactions: { contract_id: contract.id })
                                   .where("entries.date > ?", contract.ends_on)
                                   .count
        { id: contract.id, name: contract.name, ends_on: contract.ends_on.iso8601, payments_after_end: count } if count.positive?
      end
    end
end
