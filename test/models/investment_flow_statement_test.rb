require "test_helper"

class InvestmentFlowStatementTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = users(:empty)
    @account = @family.accounts.create!(
      owner: @user,
      name: "Brokerage",
      balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    @period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
  end

  test "period totals count deposits and withdrawals the way the return calculation does" do
    create_flow(label: "Contribution", amount: -125, date: @period.start_date)
    create_flow(label: nil, amount: -25, date: @period.start_date)
    create_flow(label: "Withdrawal", amount: 45, date: @period.start_date)
    create_flow(label: "Transfer", amount: 5, date: @period.start_date)
    create_flow(label: "Dividend", amount: -30, date: @period.start_date)
    create_flow(label: "Buy", amount: 500, date: @period.start_date)
    create_flow(label: "Contribution", amount: -999, date: @period.start_date - 1.day)

    totals = InvestmentFlowStatement.new(@family, user: @user).period_totals(period: @period)

    assert_equal Money.new(150, "USD"), totals.contributions
    assert_equal Money.new(50, "USD"), totals.withdrawals
    assert_equal Money.new(100, "USD"), totals.net_flow
  end

  test "period totals leave out accounts that are not investment accounts" do
    depository = @family.accounts.create!(owner: @user, name: "Checking", balance: 0, currency: "USD", accountable: Depository.new)
    depository.entries.create!(
      name: "Contribution", amount: -100, date: @period.start_date, currency: "USD",
      entryable: Transaction.new(investment_activity_label: "Contribution")
    )

    totals = InvestmentFlowStatement.new(@family, user: @user).period_totals(period: @period)

    assert_equal Money.new(0, "USD"), totals.contributions
  end

  private
    def create_flow(label:, amount:, date:)
      @account.entries.create!(
        name: label || "Transfer",
        amount: amount,
        date: date,
        currency: "USD",
        entryable: Transaction.new(investment_activity_label: label)
      )
    end
end
