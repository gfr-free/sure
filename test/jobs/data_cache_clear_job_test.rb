require "test_helper"
require "ostruct"

class DataCacheClearJobTest < ActiveJob::TestCase
  include ProviderTestHelper
  include EntriesTestHelper

  setup do
    @provider = mock("provider")
    Provider::Registry.any_instance.stubs(:get_provider).returns(@provider)

    @family = Family.create!(name: "Cache clear", currency: "USD")
    @account = @family.accounts.create!(
      name: "Foreign savings",
      currency: "CAD",
      balance: 1000,
      accountable: Depository.new
    )
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: Date.current, rate: 0.7)
  end

  test "reloads the exchange rates the family needs before its accounts sync" do
    @provider.stubs(:fetch_exchange_rates).returns(provider_success_response([
      OpenStruct.new(from: "CAD", to: "USD", date: Date.current, rate: 0.73)
    ]))

    DataCacheClearJob.perform_now(@family)

    assert_enqueued_jobs 1, only: SyncJob
    assert_equal 0.73, ExchangeRate.find_by(from_currency: "CAD", to_currency: "USD", date: Date.current)&.rate&.to_f,
      "account syncs must start with the refreshed CAD/USD rate"
  end

  test "keeps the market data and cached balances of other families" do
    @provider.stubs(:fetch_exchange_rates).returns(provider_success_response([]))
    other_rate = ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0.0067)
    other_price = Security::Price.create!(security: securities(:aapl), date: 3.days.ago.to_date, price: 200, currency: "USD")
    other_balance_ids = accounts(:depository).balances.pluck(:id)
    other_holding_ids = accounts(:investment).holdings.pluck(:id)
    assert other_balance_ids.any?
    assert other_holding_ids.any?

    DataCacheClearJob.perform_now(@family)

    assert ExchangeRate.exists?(other_rate.id)
    assert Security::Price.exists?(other_price.id)
    assert_equal other_balance_ids.sort, Balance.where(id: other_balance_ids).pluck(:id).sort
    assert_equal other_holding_ids.sort, Holding.where(id: other_holding_ids).pluck(:id).sort
  end

  test "refreshes the prices of held securities before it deletes the holdings" do
    @provider.stubs(:fetch_exchange_rates).returns(provider_success_response([]))
    brokerage = @family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "CLRC", exchange_operating_mic: "XNAS")
    brokerage.holdings.create!(security: security, date: 1.day.ago.to_date, qty: 1, price: 200, amount: 200, currency: "USD")

    Security.any_instance.expects(:import_provider_prices).with(has_entry(clear_cache: true)).once
    Security.any_instance.stubs(:import_provider_details)

    DataCacheClearJob.perform_now(@family)

    assert_empty brokerage.holdings.reload
  end

  test "deletes the family's cached balances and holdings" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")
    @account.holdings.create!(security: securities(:aapl), date: 1.day.ago.to_date, qty: 1, price: 200, amount: 200, currency: "CAD")

    DataCacheClearJob.perform_now(@family)

    assert_empty @account.balances.reload
    assert_empty @account.holdings.reload
  end

  test "keeps a cost basis the user entered through the rebuild of the holdings" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    brokerage = @family.accounts.create!(name: "Brokerage", currency: "USD", balance: 400, cash_balance: 0, accountable: Investment.new)
    create_trade(securities(:aapl), account: brokerage, qty: 2, price: 200, date: Date.current)
    Holding::Materializer.new(brokerage, strategy: :forward).materialize_holdings
    brokerage.holdings.find_by!(security: securities(:aapl), date: Date.current).set_manual_cost_basis!(150)

    DataCacheClearJob.perform_now(@family)
    Holding::Materializer.new(brokerage, strategy: :forward).materialize_holdings

    holding = brokerage.holdings.find_by!(security: securities(:aapl), date: Date.current)
    assert_equal 150, holding.cost_basis
    assert_equal "manual", holding.cost_basis_source
    assert holding.cost_basis_locked?
  end

  test "keeps a security the user remapped through the next provider import" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    brokerage, account_provider = linked_brokerage
    import_provider_holding(brokerage, account_provider, securities(:aapl), 1.day.ago.to_date).remap_security!(securities(:msft))

    DataCacheClearJob.perform_now(@family)
    import_provider_holding(brokerage, account_provider, securities(:aapl), Date.current)

    assert_equal securities(:msft), brokerage.holdings.find_by!(date: Date.current).security
  end

  test "keeps the rest of the latest provider snapshot with a corrected row" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    brokerage, account_provider = linked_brokerage
    old_snapshot = import_provider_holding(brokerage, account_provider, securities(:aapl), 2.days.ago.to_date)
    import_provider_holding(brokerage, account_provider, securities(:aapl), 1.day.ago.to_date).set_manual_cost_basis!(150)
    msft = import_provider_holding(brokerage, account_provider, securities(:msft), 1.day.ago.to_date)

    DataCacheClearJob.perform_now(@family)

    assert Holding.exists?(msft.id), "the snapshot must still list every security it held"
    assert_not Holding.exists?(old_snapshot.id)
    assert_equal [ securities(:aapl), securities(:msft) ].map(&:id).sort, brokerage.current_holdings.map(&:security_id).sort
  end

  test "does not revive a cost basis the user unlocked on the latest row" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    brokerage, account_provider = linked_brokerage
    import_provider_holding(brokerage, account_provider, securities(:aapl), 2.days.ago.to_date).set_manual_cost_basis!(150)
    import_provider_holding(brokerage, account_provider, securities(:aapl), 1.day.ago.to_date).unlock_cost_basis!

    DataCacheClearJob.perform_now(@family)
    holding = import_provider_holding(brokerage, account_provider, securities(:aapl), Date.current, cost_basis: 190)

    assert_not holding.cost_basis_locked?
    assert_equal 190, holding.cost_basis
  end

  test "drops a cost basis the user entered on a row that is no longer the position's latest" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    older = @account.holdings.create!(security: securities(:aapl), date: 2.days.ago.to_date, qty: 1, price: 200, amount: 200, currency: "CAD")
    older.set_manual_cost_basis!(150)
    @account.holdings.create!(security: securities(:aapl), date: 1.day.ago.to_date, qty: 1, price: 200, amount: 200, currency: "CAD")

    DataCacheClearJob.perform_now(@family)

    assert_empty @account.holdings.reload
  end

  test "drops a provider's corrected row that is not on its latest snapshot" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    brokerage, account_provider = linked_brokerage
    import_provider_holding(brokerage, account_provider, securities(:aapl), 2.days.ago.to_date).set_manual_cost_basis!(150)
    import_provider_holding(brokerage, account_provider, securities(:msft), 1.day.ago.to_date)

    DataCacheClearJob.perform_now(@family)

    assert_empty brokerage.holdings.reload
  end

  test "keeps each provider's corrected snapshot on an account linked to two providers" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    brokerage, first_provider = linked_brokerage
    simplefin_item = SimplefinItem.create!(family: @family, name: "SimpleFin", access_url: "https://example.com/access")
    simplefin_account = simplefin_item.simplefin_accounts.create!(name: "SimpleFin", account_id: "sf_1", account_type: "investment", currency: "USD", current_balance: 200)
    second_provider = AccountProvider.create!(account: brokerage, provider: simplefin_account)
    corrected = import_provider_holding(brokerage, first_provider, securities(:aapl), 2.days.ago.to_date)
    corrected.set_manual_cost_basis!(150)
    other = import_provider_holding(brokerage, second_provider, securities(:msft), 1.day.ago.to_date)

    DataCacheClearJob.perform_now(@family)

    assert Holding.exists?(corrected.id)
    assert_not Holding.exists?(other.id)
  end

  test "rolls the delete back when the sync cannot be scheduled" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    balance = @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")
    @family.stubs(:sync_later).raises(ActiveRecord::StatementInvalid, "connection lost")

    assert_raises(ActiveRecord::StatementInvalid) { DataCacheClearJob.perform_now(@family) }

    assert Balance.exists?(balance.id)
  end

  test "waits for a running sync instead of deleting the balances it writes" do
    Family::MarketDataRefresher.any_instance.expects(:refresh).never
    balance = @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")
    @account.syncs.create!(status: "syncing")

    assert_enqueued_with(job: DataCacheClearJob, args: [ @family ]) do
      DataCacheClearJob.perform_now(@family)
    end

    assert Balance.exists?(balance.id)
    assert_no_enqueued_jobs only: SyncJob
  end

  test "waits when a sync starts while the market data is refreshed" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh).with { @family.syncs.create!(status: "pending") }
    balance = @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")

    assert_enqueued_with(job: DataCacheClearJob, args: [ @family ]) do
      DataCacheClearJob.perform_now(@family)
    end

    assert Balance.exists?(balance.id)
  end

  test "locks the family's accounts before it checks for running syncs" do
    Family::MarketDataRefresher.any_instance.stubs(:refresh)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      DataCacheClearJob.perform_now(@family)
    end

    lock_index = queries.index { |sql| sql.match?(/FROM "accounts".*FOR UPDATE/m) }
    sync_check_index = queries.rindex { |sql| sql.match?(/FROM "syncs"/) && sql.include?("EXISTS") || sql.match?(/SELECT 1 AS one FROM "syncs"/) }
    assert lock_index, "accounts are not locked"
    assert lock_index < sync_check_index, "accounts are locked only after the running-sync check"
  end

  test "clears the balances and syncs when no exchange rate provider is set" do
    Setting.stubs(:exchange_rate_provider).returns(nil)
    Security.stubs(:provider).returns(nil)
    balance = @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => nil) do
      DataCacheClearJob.perform_now(@family)
    end

    assert_not Balance.exists?(balance.id)
    assert_enqueued_jobs 1, only: SyncJob
  end

  test "clears the balances and syncs when the exchange rate provider is unknown" do
    Provider::Registry.any_instance.stubs(:get_provider).raises(Provider::Registry::Error)
    Setting.stubs(:exchange_rate_provider).returns("nope")
    Security.stubs(:provider).returns(nil)
    balance = @account.balances.create!(date: 1.day.ago.to_date, balance: 1000, currency: "CAD")

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => nil) do
      DataCacheClearJob.perform_now(@family)
    end

    assert_not Balance.exists?(balance.id)
    assert_enqueued_jobs 1, only: SyncJob
  end

  private
    def linked_brokerage
      brokerage = @family.accounts.create!(name: "Linked brokerage", currency: "USD", balance: 400, cash_balance: 0, accountable: Investment.new)
      coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
      coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
      [ brokerage, AccountProvider.create!(account: brokerage, provider: coinstats_account) ]
    end

    def import_provider_holding(account, account_provider, security, date, cost_basis: nil)
      Account::ProviderImportAdapter.new(account).import_holding(
        security: security, quantity: 1, amount: 200, price: 200, currency: "USD", date: date,
        cost_basis: cost_basis, source: "coinstats", account_provider_id: account_provider.id
      )
    end
end
