require "test_helper"

class MarketDataResetJobTest < ActiveJob::TestCase
  setup do
    @exchange_rate = exchange_rates(:one)
    @security_price = Security::Price.create!(security: securities(:aapl), date: Date.new(2000, 1, 3), price: 200, currency: "USD")
  end

  test "deletes market data, re-imports it, then syncs every family" do
    sequence = sequence("reset")
    MarketDataImporter.any_instance.expects(:import_security_prices).in_sequence(sequence).with do
      assert_not Security::Price.exists?(@security_price.id), "prices must be gone before the re-import"
      true
    end
    MarketDataImporter.any_instance.expects(:import_exchange_rates).in_sequence(sequence).with do
      assert_not ExchangeRate.exists?(@exchange_rate.id), "rates must be gone before the re-import"
      assert_no_enqueued_jobs only: SyncJob
      true
    end

    MarketDataResetJob.perform_now

    assert_enqueued_jobs Family.count, only: SyncJob
  end

  test "keeps account-level data and prices of offline securities" do
    stub_imports
    offline = Security.create!(ticker: "OFFL", name: "Offline Co", offline: true)
    offline_price = offline.prices.create!(date: Date.new(2000, 1, 3), price: 10, currency: "USD")
    balance = accounts(:depository).balances.create!(date: Date.current, balance: 1000, currency: "USD")
    holding = accounts(:investment).holdings.first

    MarketDataResetJob.perform_now

    assert Security::Price.exists?(offline_price.id)
    assert Balance.exists?(balance.id)
    assert Holding.exists?(holding.id)
  end

  test "still imports exchange rates and syncs every family when the price import fails" do
    MarketDataImporter.any_instance.stubs(:import_security_prices).raises(StandardError, "provider down")
    MarketDataImporter.any_instance.expects(:import_exchange_rates).once

    assert_difference -> { DebugLogEntry.where(source: "MarketDataResetJob", level: "error").count }, 1 do
      MarketDataResetJob.perform_now
    end

    assert_enqueued_jobs Family.count, only: SyncJob
  end

  private
    def stub_imports
      MarketDataImporter.any_instance.stubs(:import_security_prices)
      MarketDataImporter.any_instance.stubs(:import_exchange_rates)
    end
end
