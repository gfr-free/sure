# Reminders about contracts. Each insight is addressed to the contract's owner
# (user_id): contracts are private to their owner and shares, so a family-wide
# card would name a contract to members who cannot see it.
#
#   contract_notice_deadline          the last day to give notice is near
#   contract_price_increase           a linked bill got dearer; for insurance,
#                                     telecoms and energy that usually opens a
#                                     special right to terminate
#   contract_charges_after_end        payments kept coming after the end date
class Insight::Generators::ContractGenerator < Insight::Generator
  produces "contract_notice_deadline", "contract_price_increase",
           "contract_charges_after_end"

  DEADLINE_WINDOW_DAYS = 60
  URGENT_DEADLINE_DAYS = 14
  PRICE_CHANGE_WINDOW_DAYS = 60
  CHARGES_WINDOW_DAYS = 90
  # Kinds where a price increase typically lets the customer terminate early
  # (§40 VVG for insurance, §57 TKG for telecoms, §41 EnWG for energy).
  SPECIAL_TERMINATION_KINDS = %w[insurance mobile internet energy].freeze

  def generate
    return [] if family.recurring_transactions_disabled?

    contracts = family.contracts.includes(:merchant, :owner).to_a
    return [] if contracts.empty?

    notice_deadlines(contracts) +
      price_increases(contracts) +
      charges_after_end(contracts)
  end

  private
    def today
      @today ||= Date.current
    end

    def notice_deadlines(contracts)
      contracts.filter_map do |contract|
        schedule = contract.notice_schedule(today: today)
        deadline = schedule.notice_deadline
        next if deadline.nil? || deadline > today + DEADLINE_WINDOW_DAYS

        days_left = (deadline - today).to_i
        build_insight(
          insight_type: "contract_notice_deadline",
          priority: days_left <= URGENT_DEADLINE_DAYS ? "high" : "medium",
          title: I18n.t("insights.titles.contract_notice_deadline", name: contract.name),
          template_key: "contract_notice_deadline",
          facts: {
            name: contract.name,
            deadline: I18n.l(deadline, format: :long),
            term_ends_on: I18n.l(schedule.term_ends_on || deadline, format: :long),
            days_left: days_left
          },
          metadata: { contract_id: contract.id, deadline: deadline.iso8601, urgent: days_left <= URGENT_DEADLINE_DAYS },
          dedup_key: "contract_notice_deadline:#{contract.id}:#{deadline.iso8601}",
          user_id: contract.owner_id
        )
      end
    end

    def price_increases(contracts)
      eligible = contracts.select { |contract| contract.open?(on: today) }
      return [] if eligible.empty?

      # Grouped by owner because the insight goes to the owner: like the audit
      # tool, it must only report bills that owner can see, or it would leak
      # amounts from another member's private account.
      eligible.group_by(&:owner).flat_map do |owner, owned|
        by_id = owned.index_by(&:id)

        RecurringPriceChange.joins(:recurring_transaction)
                            .merge(RecurringTransaction.accessible_by(owner))
                            .where(recurring_transactions: { contract_id: by_id.keys, status: "active" })
                            .where(effective_on: (today - PRICE_CHANGE_WINDOW_DAYS)..today)
                            .includes(:recurring_transaction)
                            .order(effective_on: :desc)
                            .to_a
                            .select { |change| change.new_amount.abs > change.previous_amount.abs }
                            .uniq { |change| change.recurring_transaction.contract_id }
                            .map do |change|
          contract = by_id.fetch(change.recurring_transaction.contract_id)
          special = contract.kind.in?(SPECIAL_TERMINATION_KINDS)
          previous_amount = Money.new(change.previous_amount.abs, change.currency).format
          new_amount = Money.new(change.new_amount.abs, change.currency).format

          build_insight(
            insight_type: "contract_price_increase",
            priority: special ? "high" : "medium",
            title: I18n.t("insights.titles.contract_price_increase", name: contract.name),
            template_key: special ? "contract_price_increase.special" : "contract_price_increase.plain",
            facts: {
              name: contract.name,
              previous_amount: previous_amount,
              new_amount: new_amount,
              effective_on: I18n.l(change.effective_on, format: :long)
            },
            metadata: { contract_id: contract.id, price_change_id: change.id, special_termination: special },
            dedup_key: "contract_price_increase:#{contract.id}:#{change.id}",
            user_id: contract.owner_id
          )
        end
      end
    end

    # Real payments allocated to a linked bill after the contract ended: money
    # that may be owed back.
    def charges_after_end(contracts)
      ended = contracts.select { |contract| contract.ends_on.present? && contract.ends_on < today }
      return [] if ended.empty?

      ended.filter_map do |contract|
        # Scoped to the bills the owner can see, like price_increases above.
        allocations = RecurringAllocation.confirmed
                                         .joins(:entry, recurring_occurrence: :recurring_transaction)
                                         .merge(RecurringTransaction.accessible_by(contract.owner))
                                         .where(recurring_transactions: { contract_id: contract.id })
                                         .where("entries.date > ? AND entries.date >= ?", contract.ends_on, today - CHARGES_WINDOW_DAYS)
                                         .includes(:entry)
                                         .to_a
        next if allocations.empty?

        currency = allocations.first.currency
        total = allocations.select { |allocation| allocation.currency == currency }.sum(&:allocated_amount)
        latest = allocations.map { |allocation| allocation.entry.date }.max

        build_insight(
          insight_type: "contract_charges_after_end",
          priority: "high",
          title: I18n.t("insights.titles.contract_charges_after_end", name: contract.name),
          template_key: "contract_charges_after_end",
          facts: {
            name: contract.name,
            count: allocations.size,
            amount: Money.new(total, currency).format,
            ends_on: I18n.l(contract.ends_on, format: :long),
            latest_on: I18n.l(latest, format: :long)
          },
          metadata: { contract_id: contract.id, count: allocations.size, latest_on: latest.iso8601 },
          dedup_key: "contract_charges_after_end:#{contract.id}",
          user_id: contract.owner_id
        )
      end
    end
end
