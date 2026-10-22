require "test_helper"

class AccountGroupSparklinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    group_sidebar_by("currency", then_by: "account_type")
    Rails.cache.clear
  end

  test "renders the sparkline into the frame that requested it" do
    stub_builder

    get group_sparkline_url(group_key), headers: frame_header("all_asset_usd_sparkline")

    assert_response :success
    assert_select "turbo-frame#all_asset_usd_sparkline [data-controller='time-series-chart']"
  end

  test "rejects requests outside a turbo frame" do
    get group_sparkline_url(group_key)

    assert_response :bad_request
  end

  test "sums the counted accounts of a group formed by another field" do
    accounts(:connected).update!(exclude_from_reports: true)
    group = asset_group

    account_ids = requested_account_ids(group_key)

    expected = BalanceSheet::ClassificationGroup.counted_accounts(group.accounts).map(&:id) - [ accounts(:connected).id ]
    assert_equal expected.sort, account_ids.sort
    assert_not_includes account_ids, accounts(:connected).id
  end

  test "sums only the accounts of the requested subgroup" do
    subgroup = asset_group.subgroups("account_type", user: @user).find { |candidate| candidate.accounts.any? { |a| a.accountable_type == "Depository" } }

    account_ids = requested_account_ids(group_key, subgroup: subgroup.token)

    assert_includes account_ids, accounts(:depository).id
    assert Account.where(id: account_ids).all? { |account| account.accountable_type == "Depository" }
  end

  test "skips accounts the member cannot access" do
    sign_in member = users(:family_member)
    group_sidebar_by("currency", user: member)

    account_ids = requested_account_ids(group_key(member))

    assert_includes account_ids, accounts(:depository).id
    assert_not_includes account_ids, accounts(:connected).id
  end

  test "skips shared accounts not included in the member's finances" do
    sign_in member = users(:family_member)
    group_sidebar_by("currency", user: member)
    account_shares(:depository_shared_with_member).update!(include_in_finances: false)

    assert_not_includes requested_account_ids(group_key(member)), accounts(:depository).id
  end

  test "an unknown group renders an empty frame" do
    get group_sparkline_url("currency_unknown"), headers: frame_header("missing_sparkline")

    assert_response :success
    assert_select "turbo-frame#missing_sparkline"
    assert_select "turbo-frame [data-controller='time-series-chart']", count: 0
  end

  test "a group of debts favors a falling balance" do
    key = @user.family.balance_sheet(user: @user).liabilities.account_groups(by: "currency", user: @user).first.key
    favorable_direction = nil
    Balance::ChartSeriesBuilder.expects(:new).with { |args| favorable_direction = args[:favorable_direction]; true }
      .returns(stub(balance_series: empty_series))

    get group_sparkline_url(key, classification: "liability"), headers: frame_header("debt_sparkline")

    assert_response :success
    assert_equal "down", favorable_direction
  end

  test "cache is not shared between users with different access" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    get group_sparkline_url(group_key), headers: frame_header("asset_sparkline")
    assert_response :success

    sign_in member = users(:family_member)
    group_sidebar_by("currency", user: member)

    assert_not_includes requested_account_ids(group_key(member), clear_cache: false), accounts(:connected).id
  end

  test "linked investment accounts are trimmed like the type sparkline" do
    AccountProvider.create!(account: accounts(:investment), provider: snaptrade_accounts(:fidelity_401k))
    Balance::LinkedInvestmentSeriesNormalizer.expects(:aggregate_account_ids)
      .with { |args| args[:account_ids].include?(accounts(:investment).id) }
      .returns(empty_series)

    get group_sparkline_url(group_key), headers: frame_header("asset_sparkline")

    assert_response :success
  end

  private
    def group_sidebar_by(primary, then_by: nil, user: @user)
      user.update!(preferences: user.preferences.merge(
        "preview_features_enabled" => true,
        "account_grouping_primary" => { "sidebar" => primary },
        "account_grouping" => { "sidebar" => then_by }
      ))
    end

    def asset_group(user = @user)
      user.family.balance_sheet(user: user).assets.account_groups(by: "currency", user: user)
        .find { |group| group.accounts.any? { |account| account.id == accounts(:depository).id } }
    end

    def group_key(user = @user)
      asset_group(user).key
    end

    def group_sparkline_url(key, classification: "asset", subgroup: nil)
      account_group_sparkline_url(classification: classification, group: key, subgroup: subgroup)
    end

    def frame_header(id)
      { "Turbo-Frame" => id }
    end

    def empty_series
      Series.new(start_date: 1.day.ago.to_date, end_date: Date.current, interval: "1 day", values: [])
    end

    def stub_builder
      Balance::ChartSeriesBuilder.stubs(:new).returns(stub(balance_series: empty_series))
    end

    def requested_account_ids(key, subgroup: nil, clear_cache: true)
      Rails.cache.clear if clear_cache
      account_ids = nil
      Balance::ChartSeriesBuilder.stubs(:new).with { |args| account_ids = args[:account_ids]; true }
        .returns(stub(balance_series: empty_series))

      get group_sparkline_url(key, subgroup: subgroup), headers: frame_header("asset_sparkline")

      assert_response :success
      # No counted account left: the frame renders empty without building a series.
      account_ids || []
    end
end
