require "test_helper"
require "ostruct"

# A second sync importing the same pair must wait for the first instead of
# returning without rates: the account sync that called it materializes right after.
class ExchangeRate::ImportLockTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    ExchangeRate.delete_all

    @provider = mock("provider")
    ExchangeRate.stubs(:provider).returns(@provider)

    @family = Family.create!(name: "Lock", currency: "USD")
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    @entry_date = 3.days.ago.to_date
    @account.entries.create!(date: @entry_date, name: "Refund", amount: -100, currency: "EUR", entryable: Transaction.new)

    @provider.stubs(:fetch_exchange_rates).returns(
      provider_success_response(
        (@entry_date - 5.days).upto(Date.current).map { |d| OpenStruct.new(from: "EUR", to: "USD", date: d, rate: 1.1) }
      )
    )
    # Single-day lookups during materialization are rate-limited after the burst of syncs.
    @provider.stubs(:fetch_exchange_rate).returns(provider_error_response(StandardError.new("rate limited")))

    # Another worker (a parallel account sync or the daily import) on its own connection.
    # A raw connection: the test pool shares one connection across checkouts, and
    # advisory locks are re-entrant within a session.
    @other_worker = PG.connect(**ActiveRecord::Base.connection_db_config.configuration_hash
                                 .slice(:host, :port, :user, :password)
                                 .merge(dbname: ActiveRecord::Base.connection_db_config.database)
                                 .compact)
    @lock_key = Digest::MD5.hexdigest("exchange_rate_import:EUR:USD").to_i(16) % (2**62)
  end

  teardown do
    @other_worker.close
  end

  test "an account sync waits for another worker's import of the same pair" do
    hold_lock_in_other_worker
    ExchangeRate.expects(:sleep).with { |seconds| seconds == 1 && release_lock_in_other_worker }.once

    Account::MarketDataImporter.new(@account).import_exchange_rates

    assert ExchangeRate.exists?(from_currency: "EUR", to_currency: "USD", date: @entry_date),
           "EUR/USD for the entry date should exist once the account's market data import returns"
    assert_equal 0, Balance::SyncCache.new(@account).unconvertible_entry_count,
                 "the EUR entry should be converted, not dropped from the balance"
  end

  test "imports anyway and logs when the other worker still holds the lock after the wait" do
    hold_lock_in_other_worker
    ExchangeRate.expects(:sleep).with(1).times(120)

    assert_difference -> { DebugLogEntry.where(category: "exchange_rate_import").count }, 1 do
      Account::MarketDataImporter.new(@account).import_exchange_rates
    end

    assert ExchangeRate.exists?(from_currency: "EUR", to_currency: "USD", date: @entry_date)
  end

  test "imports without waiting when no other worker holds the lock" do
    ExchangeRate.expects(:sleep).never

    Account::MarketDataImporter.new(@account).import_exchange_rates

    assert ExchangeRate.exists?(from_currency: "EUR", to_currency: "USD", date: @entry_date)
    assert other_worker_can_lock?, "the lock should be released after the import"
  end

  test "releases the lock when the import raises" do
    ExchangeRate::Importer.any_instance.stubs(:import_provider_rates).raises(StandardError, "provider down")

    assert_raises(StandardError) do
      ExchangeRate.import_provider_rates(from: "EUR", to: "USD", start_date: @entry_date, end_date: Date.current)
    end

    assert other_worker_can_lock?, "the lock should be released after a failed import"
  end

  private
    def hold_lock_in_other_worker
      assert other_worker_can_lock?
    end

    def release_lock_in_other_worker
      @other_worker.exec("SELECT pg_advisory_unlock(#{@lock_key})")
      true
    end

    def other_worker_can_lock?
      @other_worker.exec("SELECT pg_try_advisory_lock(#{@lock_key})").getvalue(0, 0) == "t"
    end
end
