# frozen_string_literal: true

require "test_helper"

class Api::V1::HoldingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @account = accounts(:investment)
    @holding = holdings(:one)

    # An account owned by another family member, never shared with @user.
    @other_member = users(:family_member)
    @private_account = @family.accounts.create!(
      name: "Member Brokerage",
      accountable: Investment.new,
      balance: 5000,
      currency: "USD",
      owner: @other_member
    )
    @private_holding = @private_account.holdings.create!(
      security: securities(:msft),
      date: Date.current,
      qty: 5,
      price: 100,
      amount: 500,
      currency: "USD"
    )
  end

  test "lists holdings scoped to accessible accounts" do
    get api_v1_holdings_url, headers: api_headers(@api_key)

    assert_response :success
    holding_ids = JSON.parse(response.body)["holdings"].map { |holding| holding["id"] }
    assert_includes holding_ids, @holding.id
    assert_not_includes holding_ids, @private_holding.id
  end

  test "account_ids filter cannot reach inaccessible accounts" do
    get api_v1_holdings_url,
        params: { account_ids: [ @private_account.id ] },
        headers: api_headers(@api_key)

    assert_response :success
    holding_ids = JSON.parse(response.body)["holdings"].map { |holding| holding["id"] }
    assert_not_includes holding_ids, @private_holding.id
  end

  test "account_id filter cannot reach inaccessible accounts" do
    get api_v1_holdings_url,
        params: { account_id: @private_account.id },
        headers: api_headers(@api_key)

    assert_response :success
    holding_ids = JSON.parse(response.body)["holdings"].map { |holding| holding["id"] }
    assert_not_includes holding_ids, @private_holding.id
  end

  test "shows an accessible holding" do
    get api_v1_holding_url(@holding), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @holding.id, response_data["id"]
  end

  test "returns not found for an inaccessible holding" do
    get api_v1_holding_url(@private_holding), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "requires authentication" do
    get api_v1_holdings_url

    assert_response :unauthorized
  end

  test "remap_security moves the holding and its trades to an existing security" do
    trade = @account.trades.find_by!(security: securities(:aapl))

    patch remap_security_api_v1_holding_url(@holding),
          params: { holding: { security_id: securities(:msft).id } },
          headers: api_headers(write_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "MSFT", response_data.dig("security", "ticker")
    assert_equal securities(:msft), @holding.reload.security
    assert @holding.security_locked?
    assert_equal securities(:msft), trade.reload.security
  end

  test "remap_security resolves a ticker without a security provider" do
    Security.stubs(:providers).returns([])

    patch remap_security_api_v1_holding_url(@holding),
          params: { holding: { ticker: "newt" } },
          headers: api_headers(write_api_key)

    assert_response :success
    new_security = Security.find_by!(ticker: "NEWT")
    assert new_security.offline?
    assert_equal new_security, @holding.reload.security
  end

  test "remap_security rejects a missing or cash security" do
    cash = Security.cash_for(@account)

    [ {}, { security_id: cash.id }, { ticker: cash.ticker }, { security_id: SecureRandom.uuid } ].each do |holding_params|
      patch remap_security_api_v1_holding_url(@holding),
            params: { holding: holding_params },
            headers: api_headers(write_api_key)

      assert_response :unprocessable_entity
    end
    assert_equal securities(:aapl), @holding.reload.security
  end

  test "remap_security requires the write scope" do
    patch remap_security_api_v1_holding_url(@holding),
          params: { holding: { security_id: securities(:msft).id } },
          headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal securities(:aapl), @holding.reload.security
  end

  test "remap_security cannot reach accounts the user may only read" do
    @private_account.account_shares.create!(user: @user, permission: "read_only")

    patch remap_security_api_v1_holding_url(@private_holding),
          params: { holding: { security_id: securities(:aapl).id } },
          headers: api_headers(write_api_key)

    assert_response :not_found
    assert_equal securities(:msft), @private_holding.reload.security
  end

  test "remap_security requires authentication and an existing holding" do
    patch remap_security_api_v1_holding_url(@holding), params: { holding: { security_id: securities(:msft).id } }
    assert_response :unauthorized

    patch remap_security_api_v1_holding_url(SecureRandom.uuid),
          params: { holding: { security_id: securities(:msft).id } },
          headers: api_headers(write_api_key)
    assert_response :not_found
  end

  private

    def write_api_key
      @write_api_key ||= ApiKey.create!(
        user: @user,
        name: "Test Write Key",
        scopes: [ "read_write" ],
        source: "mobile",
        display_key: "test_write_#{SecureRandom.hex(8)}"
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
