# Exemption orders per bank (taxes on returns, decision E20, STEUER.md S-2).
# For every person with a tax profile this year it points out:
#
# - a bank whose returns this year reached the exemption order given to it,
#   so further returns there are taxed;
# - exemption orders that add up to more than the person's allowance.
#
# Both are keyed per person, bank and year, so they expire with the year or
# once the orders are corrected. Insights only run for preview families
# (decision E10).
class Insight::Generators::TaxAllowanceGenerator < Insight::Generator
  produces "tax_allowance"

  def generate
    year = Account.liquidity_today_for(family).year

    people = family.users.to_a

    # Insights are shown family-wide, so only count accounts every member can see.
    people.flat_map do |person|
      estimate = Tax::Estimate.new(person, year: year, viewer: people)
      next [] unless estimate.profile?

      used_up = estimate.banks.select(&:used_up?).map { |bank| used_up_insight(person, estimate, bank) }
      used_up + [ over_allocated_insight(person, estimate) ].compact
    end
  end

  private
    def used_up_insight(person, estimate, bank)
      build_insight(
        insight_type: "tax_allowance",
        priority: "medium",
        title: I18n.t("insights.titles.tax_allowance_used_up", bank: bank.label),
        template_key: "tax_allowance_used_up",
        facts: {
          person: person.display_name,
          bank: bank.label,
          allocation: Money.new(bank.allocation, estimate.currency).format,
          income: Money.new(bank.income, estimate.currency).format,
          year: estimate.year
        },
        metadata: { user_id: person.id, bank: bank.label, year: estimate.year },
        dedup_key: "tax_allowance_used_up:#{person.id}:#{estimate.year}:#{Digest::SHA256.hexdigest(bank.label).first(12)}"
      )
    end

    def over_allocated_insight(person, estimate)
      return nil unless estimate.over_allocated?

      build_insight(
        insight_type: "tax_allowance",
        priority: "medium",
        title: I18n.t("insights.titles.tax_allowance_over_allocated"),
        template_key: "tax_allowance_over_allocated",
        facts: {
          person: person.display_name,
          allocated: Money.new(estimate.allocated_allowance, estimate.currency).format,
          allowance: Money.new(estimate.profile.annual_allowance, estimate.currency).format,
          year: estimate.year
        },
        metadata: { user_id: person.id, year: estimate.year },
        dedup_key: "tax_allowance_over_allocated:#{person.id}:#{estimate.year}"
      )
    end
end
