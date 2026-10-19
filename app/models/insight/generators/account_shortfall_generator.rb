# Warns per account when the payments expected on it would take it below zero
# before more money arrives (decision E13, Account::Forecast). This is the
# bills-account case: an account funded by a standing transfer that the
# family-wide CashFlowWarningGenerator cannot see, because that one sums every
# cash account and skips transfers.
#
# High priority, so the existing push delivery picks it up. Insights only run
# for preview families, which is the gate decision E10 asks for.
class Insight::Generators::AccountShortfallGenerator < Insight::Generator
  produces "account_shortfall"

  # Coarse enough that a few cents of drift do not read as a new insight every
  # night (see CashFlowWarningGenerator).
  LOW_BUCKET = 50

  # The feed, push and API insights are family-wide, so only accounts every
  # active member can access take part: the name and balance of a private
  # account must not reach the others (same rule as AccountReleaseGenerator).
  def self.shortfalls(family)
    shared = family.users.where(active: true).map { |user| family.accounts.accessible_by(user).pluck(:id) }.reduce(:&) || []

    Account::Forecast.for_family(family).select { |forecast| forecast.shortfall? && forecast.account.id.in?(shared) }
  end

  def generate
    self.class.shortfalls(family).map { |forecast| insight_for(forecast) }
  end

  private
    # The insight is shown to the whole family, but a transfer's other end may
    # be an account some members cannot see. Name the cause only when it is a
    # bill on this account itself.
    def shareable_cause(forecast)
      cause = forecast.low_cause
      cause if cause&.kind == :expense
    end

    def insight_for(forecast)
      account = forecast.account
      cause = shareable_cause(forecast)
      template_key = cause ? "account_shortfall.with_cause" : "account_shortfall.plain"
      facts = {
        account: account.name,
        projected_low: forecast.low_balance.format,
        projected_low_date: I18n.l(forecast.low_on),
        shortfall: forecast.shortfall_amount.format,
        top_up_by: I18n.l(forecast.top_up_by),
        current_balance: forecast.starting_balance.format
      }
      facts.merge!(cause: cause.name, cause_amount: cause.amount.abs.format) if cause

      build_insight(
        insight_type: "account_shortfall",
        priority: "high",
        title: I18n.t("insights.titles.account_shortfall", account: account.name),
        template_key: template_key,
        facts: facts,
        # Per account, month and amount bucket (concept 7.11), never the low
        # date: that moves with every payment and would read as new nightly.
        metadata: {
          account_id: account.id,
          negative: true,
          projected_low_bucket: (round(forecast.low_balance.amount, 0).to_i / LOW_BUCKET) * LOW_BUCKET
        },
        period: Period.custom(start_date: forecast.starts_on, end_date: forecast.ends_on),
        dedup_key: "account_shortfall:#{account.id}:#{month_token(forecast.starts_on)}"
      )
    end
end
