require "test_helper"

class AccountableSparklinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "should get show for depository" do
    get accountable_sparkline_url("depository")
    assert_response :success
  end

  test "show renders an empty series without a trend" do
    empty_series = Series.new(
      start_date: 1.day.ago.to_date,
      end_date: Date.current,
      interval: "1 day",
      values: []
    )
    Rails.cache.clear
    Balance::ChartSeriesBuilder.any_instance.expects(:balance_series).returns(empty_series)

    get accountable_sparkline_url("depository")

    assert_response :success
    assert_select "p.font-mono", count: 0
  end

  test "linked investment sparkline does not load full account records" do
    AccountProvider.create!(
      account: accounts(:investment),
      provider: snaptrade_accounts(:fidelity_401k)
    )

    Rails.cache.clear

    queries = capture_sql_queries do
      get accountable_sparkline_url("investment")
    end

    assert_response :success
    assert_match(/SELECT .*"accounts"\."id".*"account_providers"\."id" FROM "accounts"/, queries.join("\n"))
    assert_empty queries.grep(/SELECT "accounts"\.\* FROM "accounts"/)
    assert_empty queries.grep(/SELECT 1 AS one FROM "accounts".*JOIN "account_providers"/)
    assert_empty queries.grep(/SELECT "accounts"\."id" FROM "accounts" WHERE "accounts"\."family_id" = .*"accounts"\."status" IN .*"accounts"\."accountable_type" =/)
  end

  test "sparkline skips accounts excluded from reports" do
    accounts(:connected).update!(exclude_from_reports: true)

    account_ids = sparkline_account_ids("depository")

    assert_includes account_ids, accounts(:depository).id
    assert_not_includes account_ids, accounts(:connected).id
  end

  test "sparkline skips shared accounts not included in the member's finances" do
    sign_in users(:family_member)
    account_shares(:depository_shared_with_member).update!(include_in_finances: false)

    assert_not_includes sparkline_account_ids("depository"), accounts(:depository).id
  end

  test "sparkline cache follows the member's finance setting" do
    sign_in users(:family_member)
    share = account_shares(:depository_shared_with_member)

    assert_includes sparkline_account_ids("depository"), accounts(:depository).id

    share.update!(include_in_finances: false)

    assert_not_includes sparkline_account_ids("depository", clear_cache: false), accounts(:depository).id
  end

  private
    def sparkline_account_ids(accountable_key, clear_cache: true)
      Rails.cache.clear if clear_cache
      account_ids = nil
      series = Series.new(start_date: 1.day.ago.to_date, end_date: Date.current, interval: "1 day", values: [])
      builder = mock("chart_series_builder")
      builder.stubs(:balance_series).returns(series)
      Balance::ChartSeriesBuilder.expects(:new).with { |args| account_ids = args[:account_ids]; true }.returns(builder)

      get accountable_sparkline_url(accountable_key)

      assert_response :success
      account_ids
    end

    def capture_sql_queries
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached]
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        queries << payload[:sql].squish
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end
end
