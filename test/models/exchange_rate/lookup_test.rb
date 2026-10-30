require "test_helper"

class ExchangeRate::LookupTest < ActiveSupport::TestCase
  setup do
    ExchangeRate.delete_all
    @day = Date.new(2026, 3, 10)
  end

  test "uses the rate of the same day" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @day, rate: 1.2)

    lookup = ExchangeRate::Lookup.new(currencies: [ "EUR" ], dates: [ @day ], to: "USD")

    assert_equal 1.2, lookup.rate(from: "EUR", date: @day)
    assert_equal Money.new(12, "USD"), lookup.convert(Money.new(10, "EUR"), date: @day)
  end

  test "falls back to the nearest earlier rate within the lookback window" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @day - 3.days, rate: 1.1)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @day + 1.day, rate: 1.3)

    lookup = ExchangeRate::Lookup.new(currencies: [ "EUR" ], dates: [ @day ], to: "USD")

    assert_equal 1.1, lookup.rate(from: "EUR", date: @day)
  end

  test "returns nil without asking the provider when no rate is cached in the window" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @day - 6.days, rate: 1.1)
    ExchangeRate.expects(:find_or_fetch_rate).never

    lookup = ExchangeRate::Lookup.new(currencies: [ "EUR", "GBP" ], dates: [ @day ], to: "USD")

    assert_nil lookup.rate(from: "EUR", date: @day)
    assert_nil lookup.rate(from: "GBP", date: @day)
    assert_nil lookup.convert(Money.new(10, "EUR"), date: @day)
  end

  test "the target currency converts 1:1" do
    lookup = ExchangeRate::Lookup.new(currencies: [ "USD" ], dates: [ @day ], to: "USD")

    assert_equal Money.new(10, "USD"), lookup.convert(Money.new(10, "USD"), date: @day)
  end

  test "loads rates for every currency and date with one query" do
    dates = (0..20).map { |offset| @day - offset.days }
    dates.each do |date|
      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 1.1)
      ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: date, rate: 1.3)
    end

    lookup = ExchangeRate::Lookup.new(currencies: [ "EUR", "GBP" ], dates: dates, to: "USD")

    assert_queries_count(1) do
      dates.each do |date|
        lookup.rate(from: "EUR", date: date)
        lookup.rate(from: "GBP", date: date)
      end
    end
  end
end
