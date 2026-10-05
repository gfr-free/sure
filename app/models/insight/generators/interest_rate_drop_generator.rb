# Points out a credit rate that is about to drop, typically the end of a
# teaser rate (liquidity concept, decision E18: "teaser rate ends"). It names
# the date, both rates and what the drop costs per month at today's balance,
# so the user can move the money in time.
#
# Shown from LEAD_DAYS before the change through the day before it; once the
# new rate applies the dedup key is no longer produced and the insight
# expires. Insights only run for preview families (decision E10).
class Insight::Generators::InterestRateDropGenerator < Insight::Generator
  produces "interest_rate_drop"

  LEAD_DAYS = 14

  def generate
    upcoming_changes.filter_map { |entry| insight_for(entry) }
  end

  private
    def today
      @today ||= Account.liquidity_today_for(family)
    end

    def upcoming_changes
      Account::InterestRate.credit
        .joins(:account)
        .merge(family.accounts.visible.where(accountable_type: Account::Interest::CREDIT_TYPES))
        .where(effective_from: (today + 1)..(today + LEAD_DAYS))
        .includes(account: :interest_rates)
        .order(:effective_from)
    end

    def insight_for(entry)
      account = entry.account
      previous = account.interest_rate_on(entry.effective_from - 1, applies_to: "credit")
      return nil if previous.nil? || entry.rate >= previous

      balance = account.balance.to_d
      monthly_loss = balance.positive? ? (balance * (previous - entry.rate) / 100 / 12).round(2) : 0

      build_insight(
        insight_type: "interest_rate_drop",
        priority: "medium",
        title: I18n.t("insights.titles.interest_rate_drop", account: account.name),
        template_key: "interest_rate_drop",
        facts: {
          account: account.name,
          change_on: I18n.l(entry.effective_from),
          previous_rate: format_rate(previous),
          new_rate: format_rate(entry.rate),
          balance: Money.new(balance, account.currency).format,
          monthly_loss: Money.new(monthly_loss, account.currency).format
        },
        metadata: {
          account_id: account.id,
          change_on: entry.effective_from.iso8601,
          previous_rate: previous.to_f,
          new_rate: entry.rate.to_f
        },
        dedup_key: "interest_rate_drop:#{account.id}:#{entry.effective_from.iso8601}"
      )
    end

    def format_rate(rate)
      ActiveSupport::NumberHelper.number_to_percentage(rate, precision: 2, strip_insignificant_zeros: true, locale: I18n.locale)
    end
end
