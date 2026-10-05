require "test_helper"

class BalanceSheet::NetWorthBreakdownSeriesBuilderTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @family = families(:dylan_family)
    @family.accounts.each { |account| account.balances.destroy_all }

    @asset_account = accounts(:depository)
    @liability_account = accounts(:credit_card)
  end

  test "builds monthly points with group breakdown that sums to net worth" do
    period = Period.custom(start_date: Date.new(2026, 4, 15), end_date: Date.new(2026, 7, 15))

    create_balance(account: @asset_account, date: period.start_date, balance: 5000)
    create_balance(account: @asset_account, date: period.end_date, balance: 6000)
    create_balance(account: @liability_account, date: period.start_date, balance: 1000)
    create_balance(account: @liability_account, date: period.end_date, balance: 1500)

    series = builder.breakdown_series(period: period)

    # One point per month in the period, end date included
    assert_equal 4, series[:values].size
    assert_equal period.start_date, series[:values].first[:date]
    assert_equal period.end_date, series[:values].last[:date]

    last_point = series[:values].last

    # Liabilities are reported as positive magnitudes
    assert_equal 6000, last_point[:assets].amount
    assert_equal 1500, last_point[:liabilities].amount
    assert_equal 4500, last_point[:value].amount

    # Every point's net worth equals assets minus liabilities
    series[:values].each do |point|
      assert_equal point[:value].amount, point[:assets].amount - point[:liabilities].amount
    end

    # Each point's trend is the month-over-month change from the previous
    # point; the first point has no prior month so its trend is flat
    assert_equal 0, series[:values].first[:trend].value.amount
    series[:values].each_cons(2) do |previous, point|
      assert_equal point[:value].amount - previous[:value].amount, point[:trend].value.amount
    end
  end

  test "includes group metadata and excludes groups with no balances" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))

    create_balance(account: @asset_account, date: period.end_date, balance: 5000)
    create_balance(account: @liability_account, date: period.end_date, balance: 1000)

    series = builder.breakdown_series(period: period)
    groups = series[:values].last[:groups]

    # Only account types with balances appear; assets sort before liabilities
    assert_equal [ "asset", "liability" ], groups.map { |g| g[:classification] }
    assert_equal Depository.display_name, groups.first[:name]
    assert_equal CreditCard.display_name, groups.last[:name]
    assert groups.all? { |g| g[:color].present? }
  end

  test "does not serialize a sub-unit residue the chart would plot as a move" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))

    # Both amounts print as $0.00, so the chart has to draw a flat line
    create_balance(account: @asset_account, date: period.start_date, balance: 0.0001)
    create_balance(account: @asset_account, date: period.end_date, balance: 0.0002)

    series = builder.breakdown_series(period: period)

    assert series[:values].size >= 2
    series[:values].each do |point|
      assert_equal 0, point[:value].amount
      assert point[:trend].direction.flat?, "expected no change between values printing as $0.00"
      assert point[:trend].percent.finite?, "expected a finite percentage"
    end
  end

  test "serializes a nil trend percentage when displayed value increases from zero" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))

    create_balance(account: @asset_account, date: period.start_date, balance: 0.0001)
    create_balance(account: @asset_account, date: period.end_date, balance: 1)

    series = builder.breakdown_series(period: period)
    parsed = JSON.parse(series.to_json)

    assert_equal 0, series[:values].first[:value].amount
    assert_equal 1, series[:values].last[:value].amount
    assert_nil parsed["values"].last["trend"]["percent"]
  end

  test "cache key includes payload version" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))

    assert_includes builder.send(:cache_key, period, "account_type"), BalanceSheet::NetWorthBreakdownSeriesBuilder::CACHE_VERSION
  end

  test "groups by another account field across account types" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))
    investment = accounts(:investment)
    investment.balances.destroy_all

    @asset_account.update!(custom_group: "Reserve")
    investment.update!(custom_group: "reserve ")
    @liability_account.update!(custom_group: "Reserve")

    create_balance(account: @asset_account, date: period.end_date, balance: 5000)
    create_balance(account: investment, date: period.end_date, balance: 3000)
    create_balance(account: @liability_account, date: period.end_date, balance: 1000)

    series = builder.breakdown_series(period: period, group_by: "custom_group")
    last_point = series[:values].last
    groups = last_point[:groups]

    # One asset group summing both account types, and a separate debt group
    # with the same value
    assert_equal [ [ "asset", "Reserve", 8000 ], [ "liability", "Reserve", 1000 ] ],
                 groups.map { |g| [ g[:classification], g[:name], g[:value].amount ] }
    assert_equal 7000, last_point[:value].amount
  end

  test "falls back to account types for an unknown grouping" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))
    create_balance(account: @asset_account, date: period.end_date, balance: 5000)

    groups = builder.breakdown_series(period: period, group_by: "bogus")[:values].last[:groups]

    assert_equal [ Depository.display_name ], groups.map { |g| g[:name] }
  end

  test "cache key differs per grouping" do
    period = Period.custom(start_date: Date.new(2026, 6, 15), end_date: Date.new(2026, 7, 15))

    assert_not_equal builder.send(:cache_key, period, "account_type"), builder.send(:cache_key, period, "custom_group")
  end

  private
    def builder
      BalanceSheet::NetWorthBreakdownSeriesBuilder.new(@family)
    end
end
