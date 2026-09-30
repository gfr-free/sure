module PortfolioReturnsHelper
  # A return as a signed percentage, e.g. "+6.2%" or "-1.4%"; "-" when there is
  # nothing to show (no value invested, or no rate the flows could be solved for).
  def format_portfolio_return(rate)
    return t("portfolio_returns.no_data") if rate.nil?

    percent = number_to_percentage(rate.to_d * 100, precision: 1)
    rate.positive? ? "+#{percent}" : percent
  end

  def portfolio_return_color_class(rate)
    return "text-secondary" if rate.nil? || rate.zero?

    rate.positive? ? "text-success" : "text-destructive"
  end

  # Returns over a year or more are per year; shorter ones are the actual
  # change in the period.
  def portfolio_return_basis(result)
    result.annualized ? t("portfolio_returns.per_year") : t("portfolio_returns.in_period")
  end
end
