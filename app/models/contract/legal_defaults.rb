# Typical terms for a new contract, offered as suggestions in the form and
# never applied without the user's click. Only for Germany, where the rules
# are uniform enough to suggest; everywhere else the form stays blank.
#
# Sources, simplified:
#   insurance      renews for a year; notice between one and three months,
#                  three being the usual policy wording (§11 VVG)
#   mobile/internet  minimum term of at most 24 months, then monthly (§56 TKG)
#   energy/fitness/membership  consumer contracts since March 2022 run on
#                  indefinitely after the minimum term, one month's notice (§309 Nr. 9 BGB)
#   rent           three months for the tenant (§573c BGB)
#
# Not legal advice: the contract's own wording wins, which is why the user
# confirms every value.
class Contract::LegalDefaults
  GERMANY = {
    "insurance" => { minimum_term_months: 12, notice_period_value: 3, notice_period_unit: "months",
                     notice_anchor: "end_of_term", renewal_period_months: 12 },
    "mobile" => { minimum_term_months: 24, notice_period_value: 1, notice_period_unit: "months",
                  notice_anchor: "any_day", renewal_period_months: nil },
    "internet" => { minimum_term_months: 24, notice_period_value: 1, notice_period_unit: "months",
                    notice_anchor: "any_day", renewal_period_months: nil },
    "energy" => { minimum_term_months: 12, notice_period_value: 1, notice_period_unit: "months",
                  notice_anchor: "any_day", renewal_period_months: nil },
    "fitness" => { minimum_term_months: 12, notice_period_value: 1, notice_period_unit: "months",
                   notice_anchor: "any_day", renewal_period_months: nil },
    "membership" => { minimum_term_months: nil, notice_period_value: 1, notice_period_unit: "months",
                      notice_anchor: "any_day", renewal_period_months: nil },
    "rent" => { minimum_term_months: nil, notice_period_value: 3, notice_period_unit: "months",
                notice_anchor: "end_of_month", renewal_period_months: nil }
  }.freeze

  COUNTRIES = { "DE" => GERMANY }.freeze

  class << self
    def available_for?(country)
      COUNTRIES.key?(country.to_s.upcase)
    end

    # Suggestions for every kind in the family's country, or {} when there
    # are none; the form passes them to its Stimulus controller.
    def for_country(country)
      COUNTRIES.fetch(country.to_s.upcase, {})
    end

    def for(kind:, country:)
      for_country(country)[kind.to_s]
    end
  end
end
