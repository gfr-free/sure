# "Fixed costs & contracts" for the Reports page, from the contracts one user
# can see:
#
#   by_kind     projected yearly cost per kind, from the active linked bills
#               the user can see
#   insurance   insurance premiums actually paid in the report period, from
#               confirmed bill payments, flagged when the line is commonly
#               deductible in a German tax return
class Contract::CostReport
  KindRow = Data.define(:kind, :count, :annual_cost)
  InsuranceRow = Data.define(:contract, :line, :paid, :possibly_deductible)

  attr_reader :unconvertible_count

  def initialize(family:, user:, start_date:, end_date:)
    @family = family
    @user = user
    @start_date = start_date
    @end_date = end_date
    @unconvertible_count = 0
  end

  def contracts
    @contracts ||= family.contracts.accessible_by(user).includes(:merchant).to_a
  end

  def any?
    contracts.any?
  end

  # Groups open, visible contracts by kind, sorted by descending annual cost
  # in the family currency. Counts include contracts without visible active bills.
  # Caches the rows and adds skipped bill conversions to unconvertible_count once.
  def by_kind
    @by_kind ||= begin
      open_contracts = contracts.select(&:open?)
      costs = Contract.annual_costs_for(open_contracts, user)

      open_contracts.group_by(&:kind).map do |kind, group|
        totals = group.filter_map { |contract| costs.dig(contract.id, 0) }
        @unconvertible_count += group.sum { |contract| costs.dig(contract.id, 1).to_i }
        KindRow.new(kind: kind, count: group.size, annual_cost: totals.sum(zero))
      end.sort_by { |row| -row.annual_cost.amount }
    end
  end

  def total_annual_cost
    by_kind.sum(zero) { |row| row.annual_cost }
  end

  # Returns visible insurance contracts with nonzero confirmed payments in the
  # inclusive report period, including ended contracts. Amounts use the family
  # currency at each payment date; failed conversions are omitted and counted.
  # Caches rows, sorted with possibly deductible lines first, then by amount descending.
  def insurance
    @insurance ||= begin
      insurances = contracts.select(&:insurance?)
      paid = paid_in_period(insurances)

      insurances.filter_map do |contract|
        amount = paid[contract.id]
        next if amount.nil? || amount.zero?

        InsuranceRow.new(contract: contract, line: contract.insurance_line, paid: amount,
                         possibly_deductible: contract.possibly_tax_deductible?)
      end.sort_by { |row| [ row.possibly_deductible ? 0 : 1, -row.paid.amount ] }
    end
  end

  def possibly_deductible_total
    insurance.select(&:possibly_deductible).sum(zero, &:paid)
  end

  private
    attr_reader :family, :user, :start_date, :end_date

    def zero
      Money.new(0, family.currency)
    end

    # Confirmed payments on the user's visible bills linked to these contracts,
    # dated inside the period, converted to the family currency on the day paid.
    # Returns totals keyed by contract ID. Money::ConversionError skips that
    # allocation and increments unconvertible_count.
    def paid_in_period(contracts)
      return {} if contracts.empty?

      visible_bill_ids = RecurringTransaction.accessible_by(user).where(contract_id: contracts.map(&:id)).select(:id)

      RecurringAllocation.confirmed
                         .joins(:entry, :recurring_occurrence)
                         .where(recurring_occurrences: { recurring_transaction_id: visible_bill_ids })
                         .where(entries: { date: start_date..end_date })
                         .includes(:entry, recurring_occurrence: :recurring_transaction)
                         .each_with_object(Hash.new { |hash, key| hash[key] = zero }) do |allocation, totals|
        contract_id = allocation.recurring_occurrence.recurring_transaction.contract_id
        money = Money.new(allocation.allocated_amount.abs, allocation.currency)
        totals[contract_id] += money.exchange_to(family.currency, date: allocation.entry.date)
      rescue Money::ConversionError
        @unconvertible_count += 1
      end
    end
end
