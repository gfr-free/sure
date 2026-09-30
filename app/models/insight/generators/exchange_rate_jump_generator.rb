# Flags a day-over-day jump in an exchange rate the family depends on. A rate
# that moves by more than JUMP_THRESHOLD in one day is almost always a bad
# provider value (see we-promise/sure#1381), and it silently skews every
# converted balance and report, so this is a warning rather than a nudge.
#
# Only foreign currencies the family actually holds or books in are checked,
# each against the family's primary currency — the direction balances and
# reports convert in. Gap-filled days (weekends, holidays) carry the previous
# rate forward, so they never register as a jump themselves.
class Insight::Generators::ExchangeRateJumpGenerator < Insight::Generator
  produces "exchange_rate_jump"

  JUMP_THRESHOLD = 0.10
  LOOKBACK_DAYS = 7
  MAX_INSIGHTS = 3

  Jump = Data.define(:from, :to, :date, :previous_rate, :rate, :change)

  def generate
    jumps.first(MAX_INSIGHTS).map { |jump| build_jump_insight(jump) }
  end

  private
    # One query for every pair. The window reaches one day further back than
    # the lookback so a jump on its first day still has a predecessor.
    # Newest first, largest move first within a day, so the pick is stable.
    def jumps
      return [] if foreign_currencies.empty?

      rates = ExchangeRate
        .where(from_currency: foreign_currencies, to_currency: primary_currency)
        .where(date: (window_start - 1)..Date.current)
        .order(:from_currency, :date)
        .pluck(:from_currency, :date, :rate)

      rates.group_by(&:first).flat_map do |from, rows|
        rows.each_cons(2).filter_map do |(_, _, previous_rate), (_, date, rate)|
          next if date < window_start || previous_rate.to_d.zero?

          change = (rate.to_d - previous_rate.to_d) / previous_rate.to_d
          next if change.abs <= JUMP_THRESHOLD

          Jump.new(from:, to: primary_currency, date:, previous_rate:, rate:, change:)
        end
      end.sort_by { |jump| [ -jump.date.jd, -jump.change.abs ] }
    end

    def build_jump_insight(jump)
      pair = "#{jump.from}/#{jump.to}"

      build_insight(
        insight_type: "exchange_rate_jump",
        priority: "high",
        title: I18n.t("insights.titles.exchange_rate_jump", pair: pair),
        template_key: "exchange_rate_jump",
        facts: {
          name: pair,
          pair: pair,
          from: jump.from,
          date: I18n.l(jump.date, format: :long),
          previous_rate: format_rate(jump.previous_rate),
          rate: format_rate(jump.rate),
          change_pct: signed_percent(jump.change)
        },
        metadata: {
          from_currency: jump.from,
          to_currency: jump.to,
          date: jump.date.iso8601,
          previous_rate: round(jump.previous_rate, 6),
          rate: round(jump.rate, 6),
          direction: jump.change.positive? ? "up" : "down"
        },
        dedup_key: "exchange_rate_jump:#{jump.from}:#{jump.to}:#{jump.date.iso8601}"
      )
    end

    def window_start
      Date.current - (LOOKBACK_DAYS - 1)
    end

    def primary_currency
      family.primary_currency_code
    end

    def foreign_currencies
      @foreign_currencies ||= (
        family.accounts.distinct.pluck(:currency) +
        family.entries.distinct.pluck(:currency)
      ).compact.uniq - [ primary_currency ]
    end

    def format_rate(value)
      ActiveSupport::NumberHelper.number_to_rounded(
        value.to_d, precision: 4, strip_insignificant_zeros: true, locale: I18n.locale
      )
    end

    def signed_percent(change)
      value = ActiveSupport::NumberHelper.number_to_rounded(
        (change.abs * 100), precision: 1, locale: I18n.locale
      )
      change.negative? ? "−#{value}" : "+#{value}"
    end
end
