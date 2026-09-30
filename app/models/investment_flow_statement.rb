class InvestmentFlowStatement
  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  # Money moved into and out of the investment accounts in a period, in family
  # currency. Uses the same classification as the return calculation
  # (Portfolio::ExternalFlows), so these totals and the report's return figures
  # always describe the same deposits and withdrawals.
  def period_totals(period: Period.current_month)
    result = family.investment_statement(user: user).performance(period: period).result

    PeriodTotals.new(
      contributions: result.deposits_money,
      withdrawals: result.withdrawals_money,
      net_flow: result.net_flows_money
    )
  end

  PeriodTotals = Data.define(:contributions, :withdrawals, :net_flow)
end
