require "test_helper"

class ReportsInvestmentFlowsViewTest < ActionView::TestCase
  RAW_PALETTE = /\b(?:text|bg|border)-(?:green|orange|red|gray)-\d{2,3}\b/

  test "colors the contribution and withdrawal cards with design tokens" do
    flows = InvestmentFlowStatement::PeriodTotals.new(
      contributions: Money.new(500, "USD"),
      withdrawals: Money.new(200, "USD"),
      net_flow: Money.new(300, "USD")
    )

    render partial: "reports/investment_flows", locals: { investment_flows: flows }

    assert_no_match RAW_PALETTE, rendered
    assert_no_match(/style="color:/, rendered)
    assert_select ".text-success.privacy-sensitive", text: /\$500\.00/
    assert_select ".text-warning.privacy-sensitive", text: /\$200\.00/
  end
end
