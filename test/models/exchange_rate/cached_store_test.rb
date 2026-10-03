require "test_helper"

class ExchangeRate::CachedStoreTest < ActiveSupport::TestCase
  include SqlQueryCapture

  setup do
    ExchangeRate.delete_all
    @provider = mock
    @provider.expects(:fetch_exchange_rate).never
    ExchangeRate.stubs(:provider).returns(@provider)
  end

  test "answers what find_or_fetch_rate would for stored rates" do
    today = Date.current
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: today, rate: 1.1)
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: today - 3, rate: 1.3)
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: today - 4, rate: 1.2)
    ExchangeRate.create!(from_currency: "CHF", to_currency: "USD", date: today - 10, rate: 1.4)

    store = ExchangeRate::CachedStore.new(%w[EUR GBP CHF USD], to: "USD")

    # CHF is left out: with nothing stored, find_or_fetch_rate would go to the provider.
    %w[EUR GBP].each do |from|
      assert_equal ExchangeRate.find_or_fetch_rate(from: from, to: "USD")&.rate,
                   store.find_or_fetch_rate(from: from, to: "USD", date: today)&.rate,
                   from
    end
    assert_equal 1.3, store.find_or_fetch_rate(from: "GBP", to: "USD", date: today).rate
    assert_nil store.find_or_fetch_rate(from: "CHF", to: "USD", date: today), "outside the lookback window"
  end

  test "preloaded lookups issue no further queries, however many rows convert" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)
    store = ExchangeRate::CachedStore.new(%w[EUR CHF], to: "USD")

    queries = capture_sql_queries do
      50.times do
        assert_equal Money.new(15, "USD"), Money.new(10, "EUR", store: store).exchange_to("USD")
        assert_raises(Money::ConversionError) { Money.new(10, "CHF", store: store).exchange_to("USD") }
      end
    end

    assert_empty queries
  end

  test "loads a currency it was not given once, from the database only" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)
    store = ExchangeRate::CachedStore.new([], to: "USD")

    queries = capture_sql_queries do
      3.times { assert_equal 1.5, store.find_or_fetch_rate(from: "EUR", to: "USD", date: Date.current).rate }
    end

    assert_equal 1, queries.size
  end
end
