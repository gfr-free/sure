require "test_helper"

class Insight::Generators::ExchangeRateJumpGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
  end

  test "flags a day-over-day jump in a currency the family holds" do
    eur_account
    rates("EUR", "USD", 3 => 1.10, 2 => 1.10, 1 => 1.25, 0 => 1.25)

    insights = generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "exchange_rate_jump", insight.insight_type
    assert_equal "high", insight.priority
    assert_equal "exchange_rate_jump:EUR:USD:#{1.day.ago.to_date.iso8601}", insight.dedup_key
    assert_equal "up", insight.metadata[:direction]
    assert_equal 1.1, insight.metadata[:previous_rate]
    assert_equal 1.25, insight.metadata[:rate]
    assert_equal "+13.6", insight.facts[:change_pct]
    assert_equal "EUR/USD", insight.facts[:name]
  end

  test "flags a drop with a true minus sign" do
    eur_account
    rates("EUR", "USD", 1 => 1.10, 0 => 0.95)

    insight = generate.first

    assert_equal "down", insight.metadata[:direction]
    assert_equal "−13.6", insight.facts[:change_pct]
  end

  test "a spike and its recovery are one insight, on the spike day" do
    eur_account
    rates("EUR", "USD", 3 => 1.10, 2 => 1.50, 1 => 1.10, 0 => 1.10)

    insights = generate

    assert_equal [ 2.days.ago.to_date.iso8601 ], insights.map { |i| i.metadata[:date] }
  end

  test "keeps small rates readable" do
    @family.accounts.create!(name: "Rupiah", balance: 1_000_000, currency: "IDR", accountable: Depository.new)
    rates("IDR", "USD", 1 => 0.000051, 0 => 0.000062)

    insight = generate.first

    assert_equal "0.000051", insight.facts[:previous_rate]
    assert_equal "0.000062", insight.facts[:rate]
  end

  test "ignores moves at or below the threshold" do
    eur_account
    rates("EUR", "USD", 2 => 1.00, 1 => 1.10, 0 => 1.05)

    assert_empty generate
  end

  test "ignores currencies the family does not use" do
    rates("GBP", "USD", 1 => 1.20, 0 => 2.40)

    assert_empty generate
  end

  test "ignores currencies held only in disabled accounts" do
    eur_account.update!(status: "disabled")
    rates("EUR", "USD", 1 => 1.10, 0 => 1.25)

    assert_empty generate
  end

  test "only looks at jumps inside the lookback window" do
    eur_account
    window = Insight::Generators::ExchangeRateJumpGenerator::LOOKBACK_DAYS
    # Jump one day before the window: dropped. Jump on the window's first day,
    # measured against the rate just before it: kept.
    rates("EUR", "USD", window + 1 => 1.00, window => 1.50, window - 1 => 2.00)

    insights = generate

    assert_equal [ (window - 1).days.ago.to_date.iso8601 ], insights.map { |i| i.metadata[:date] }
  end

  test "writes the insight in German" do
    @family.users.update_all(ai_enabled: false)
    eur_account
    rates("EUR", "USD", 1 => 1.10, 0 => 1.25)

    generated = I18n.with_locale(:de) { generate.first }
    body = I18n.with_locale(:de) { Insight::BodyWriter.new(@family).write(generated) }

    assert_equal "Ungewöhnlicher Wechselkurs EUR/USD", generated.title
    assert_includes body, "um +13,6 % verändert, von 1,1 auf 1,25"
    assert_includes body, "aus EUR umgerechnet"
  end

  private
    def generate
      Insight::Generators::ExchangeRateJumpGenerator.new(@family).generate
    end

    def eur_account
      @family.accounts.create!(
        name: "Euro savings", balance: 1_000, currency: "EUR", accountable: Depository.new
      )
    end

    # { days_ago => rate }
    def rates(from, to, by_days_ago)
      by_days_ago.each do |days_ago, rate|
        ExchangeRate.create!(from_currency: from, to_currency: to, date: days_ago.days.ago.to_date, rate: rate)
      end
    end
end
