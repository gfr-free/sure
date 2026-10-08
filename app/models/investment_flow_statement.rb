class InvestmentFlowStatement
  include Monetizable

  CONTRIBUTIONS_TOTAL_SQL = Arel.sql(
    "COALESCE(ABS(SUM(CASE WHEN transactions.investment_activity_label = 'Contribution' " \
    "THEN entries.amount ELSE 0 END)), 0)"
  )
  WITHDRAWALS_TOTAL_SQL = Arel.sql(
    "COALESCE(ABS(SUM(CASE WHEN transactions.investment_activity_label = 'Withdrawal' " \
    "THEN entries.amount ELSE 0 END)), 0)"
  )
  private_constant :CONTRIBUTIONS_TOTAL_SQL, :WITHDRAWALS_TOTAL_SQL

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  # Get contribution/withdrawal totals for a period
  def period_totals(period: Period.current_month)
    base = family.transactions
      .visible
      .excluding_pending
      .where(entries: { date: period.date_range })
      .where(investment_activity_label: %w[Contribution Withdrawal])

    scope = base.where(kind: %w[standard investment_contribution])
      .or(matched_contribution_inflows(base))

    if user
      account_ids = family.accounts.included_in_finances_for(user).included_in_reports.select(:id)
      scope = scope.where(entries: { account_id: account_ids })
    end

    contributions, withdrawals = scope.pick(
      CONTRIBUTIONS_TOTAL_SQL,
      WITHDRAWALS_TOTAL_SQL
    )

    PeriodTotals.new(
      contributions: Money.new(contributions, family.currency),
      withdrawals: Money.new(withdrawals, family.currency),
      net_flow: Money.new(contributions - withdrawals, family.currency)
    )
  end

  PeriodTotals = Data.define(:contributions, :withdrawals, :net_flow)

  private
    # Matching a provider "Contribution" on an investment/crypto account to its
    # cash outflow turns the inflow leg into funds_movement (Transfer#kind_for_leg),
    # so the kind filter above would drop it. Count that leg as a contribution when
    # the money comes from outside the investment/crypto accounts, the same
    # endpoint rule Transfer.kind_for_account uses. Movements between investment
    # or crypto accounts stay internal and are not counted.
    def matched_contribution_inflows(base)
      investment_types = %w[Investment Crypto]

      base
        .where(kind: "funds_movement")
        .where("transactions.investment_activity_label = 'Contribution'")
        .where(entries: { account_id: family.accounts.where(accountable_type: investment_types).select(:id) })
        .where(
          id: Transfer
            .joins(outflow_transaction: { entry: :account })
            .where(accounts: { family_id: family.id })
            .where.not(accounts: { accountable_type: investment_types })
            .select(:inflow_transaction_id)
        )
    end
end
