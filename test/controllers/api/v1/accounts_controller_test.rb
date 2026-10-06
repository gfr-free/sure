# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin) # dylan_family user
    @other_family_user = users(:family_member)
    @other_family_user.update!(family: families(:empty))

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @other_family_user.api_keys.active.destroy_all
    @other_family_api_key = ApiKey.create!(
      user: @other_family_user,
      name: "Other Family Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "other_family_read_#{SecureRandom.hex(8)}"
    )
  end

  test "should require authentication" do
    get "/api/v1/accounts"
    assert_response :unauthorized

    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should require read_accounts scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to exercise the runtime insufficient-scope guard.
    api_key_without_read.save!(validate: false)

    get "/api/v1/accounts", params: {}, headers: api_headers(api_key_without_read)

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should return user's family accounts successfully" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have accounts array
    assert response_body.key?("accounts")
    assert response_body["accounts"].is_a?(Array)

    # Should have pagination metadata
    assert response_body.key?("pagination")
    assert response_body["pagination"].key?("page")
    assert response_body["pagination"].key?("per_page")
    assert response_body["pagination"].key?("total_count")
    assert response_body["pagination"].key?("total_pages")

    # All accounts should belong to user's family
    response_body["accounts"].each do |account|
      # We'll validate this by checking the user's family has these accounts
      family_account_names = @user.family.accounts.pluck(:name)
      assert_includes family_account_names, account["name"]
    end
  end

  test "should only return active accounts" do
    # Make one account inactive
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should not include the inactive account
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_not_includes account_names, inactive_account.name
  end

  test "should include disabled accounts when requested" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts", params: { include_disabled: true }, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    account = response_body["accounts"].find { |account_data| account_data["id"] == inactive_account.id }
    assert_not_nil account
    assert_equal "disabled", account["status"]
  end

  test "should show active account" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal account.id, response_body["id"]
    assert_equal account.status, response_body["status"]
    assert_equal account.balance_money.format, response_body["balance"]
    assert_equal money_cents(account.balance_money), response_body["balance_cents"]
    assert_equal account.cash_balance_money.format, response_body["cash_balance"]
    assert_equal money_cents(account.cash_balance_money), response_body["cash_balance_cents"]
    assert_nullable_equal account.subtype, response_body["subtype"]
    assert response_body.key?("institution_name")
    assert response_body.key?("institution_domain")
    assert_nullable_equal account.institution_name, response_body["institution_name"]
    assert_nullable_equal account.institution_domain, response_body["institution_domain"]
    assert_equal account.created_at.iso8601, response_body["created_at"]
    assert_equal account.updated_at.iso8601, response_body["updated_at"]
  end

  test "should show account availability" do
    account = accounts(:depository)
    account.update!(subtype: "cd", available_on: Date.new(2030, 3, 31), notice_period_days: 30)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "locked", response_body["liquidity"]
    assert_equal "2030-03-31", response_body["available_on"]
    assert_equal 30, response_body["notice_period_days"]
    assert_equal false, response_body["available_now"]
  end

  test "should show an immediately available account as available now" do
    get "/api/v1/accounts/#{accounts(:depository).id}", headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "immediate", response_body["liquidity"]
    assert_nil response_body["available_on"]
    assert_equal true, response_body["available_now"]
  end

  test "should show interest terms, with amounts only on the single account" do
    account = accounts(:depository)
    account.update!(interest_payout_frequency: "monthly")
    account.interest_rates.create!(effective_from: 1.year.ago.to_date, rate: 3.5)
    account.interest_rates.create!(effective_from: 1.month.from_now.to_date, rate: 1.5)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

    assert_response :success
    interest = JSON.parse(response.body)["interest"]
    assert_equal "3.5", interest["rate"]
    assert_equal "monthly", interest["payout_frequency"]
    assert_equal "act_365", interest["day_count"]
    assert_equal [ "1.5" ], interest["rate_changes"].map { |change| change["rate"] }
    assert interest.key?("accrued")
    assert interest["next_payout_amount"].key?("formatted")

    get "/api/v1/accounts", headers: api_headers(@api_key)

    listed = JSON.parse(response.body)["accounts"].find { |row| row["id"] == account.id }
    assert_equal "3.5", listed["interest"]["rate"]
    assert_not listed["interest"].key?("accrued")
    assert_nil JSON.parse(response.body)["accounts"].find { |row| row["id"] == accounts(:investment).id }&.dig("interest")
  end

  test "should return 404 for unknown account on show" do
    get "/api/v1/accounts/#{SecureRandom.uuid}", headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
  end

  test "should return 404 for malformed account id on show" do
    get "/api/v1/accounts/not-a-uuid", headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
    assert_equal "Account not found", response_body["message"]
  end

  test "should require authentication on show" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}"

    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should require read scope on show" do
    account = accounts(:depository)
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Show Key",
      scopes: [],
      source: "web",
      display_key: "no_read_show_#{SecureRandom.hex(8)}"
    )
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to exercise the runtime insufficient-scope guard.
    api_key_without_read.save!(validate: false)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(api_key_without_read)

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should hide disabled account by default on show" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts/#{inactive_account.id}", headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "should show disabled account when requested" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts/#{inactive_account.id}",
        params: { include_disabled: true },
        headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal inactive_account.id, response_body["id"]
    assert_equal "disabled", response_body["status"]
  end

  test "should expose subtype across account types" do
    expected_subtypes = {
      accounts(:depository) => "checking",
      accounts(:credit_card) => "credit_card",
      accounts(:investment) => "brokerage",
      accounts(:loan) => "mortgage",
      accounts(:property) => "single_family_home",
      accounts(:vehicle) => "sedan",
      accounts(:crypto) => "exchange",
      accounts(:other_asset) => "collectible",
      accounts(:other_liability) => "personal_debt"
    }

    expected_subtypes.each { |account, subtype| account.accountable.update!(subtype: subtype) }

    expected_subtypes.each do |account, subtype|
      get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

      assert_response :success
      assert_equal subtype, JSON.parse(response.body)["subtype"]
    end
  end

  test "should not return other family's accounts" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@other_family_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should return empty array since other family has no accounts in fixtures
    assert_equal [], response_body["accounts"]
    assert_equal 0, response_body["pagination"]["total_count"]
  end

  test "should handle pagination parameters" do
    # Test with pagination params
    get "/api/v1/accounts", params: { page: 1, per_page: 2 }, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should respect per_page limit
    assert response_body["accounts"].length <= 2
    assert_equal 1, response_body["pagination"]["page"]
    assert_equal 2, response_body["pagination"]["per_page"]
  end

  test "should return proper account data structure" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have at least one account from fixtures
    assert response_body["accounts"].length > 0

    account = response_body["accounts"].first

    # Check required fields are present
    required_fields = %w[id name balance balance_cents cash_balance cash_balance_cents currency classification account_type]
    required_fields.each do |field|
      assert account.key?(field), "Account should have #{field} field"
    end

    # Check data types
    assert account["id"].is_a?(String), "ID should be string (UUID)"
    assert account["name"].is_a?(String), "Name should be string"
    assert account["balance"].is_a?(String), "Balance should be string (money)"
    assert account["balance_cents"].is_a?(Integer), "Balance cents should be integer"
    assert account["cash_balance_cents"].is_a?(Integer), "Cash balance cents should be integer"
    assert account["currency"].is_a?(String), "Currency should be string"
    assert %w[asset liability].include?(account["classification"]), "Classification should be asset or liability"
  end

  test "should handle invalid pagination parameters gracefully" do
    # Test with invalid page number
    get "/api/v1/accounts", params: { page: -1, per_page: "invalid" }, headers: api_headers(@api_key)

    # Should still return success with default pagination
    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have pagination info (with defaults applied)
    assert response_body.key?("pagination")
    assert response_body["pagination"]["page"] >= 1
    assert response_body["pagination"]["per_page"] > 0
  end

  test "should sort accounts alphabetically" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should be sorted alphabetically by name
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_equal account_names.sort, account_names
  end

  test "forecast returns what is left after the expected payments" do
    account = accounts(:depository)
    account.update!(balance: 500)
    family = account.family
    family.recurring_transactions.destroy_all
    today = Account.liquidity_today_for(family)
    series = family.recurring_transactions.create!(
      name: "Rent", account: account, amount: 650, currency: "USD", bill_type: "bill",
      expected_day_of_month: 15, last_occurrence_date: today, next_expected_date: today + 30,
      status: "active", manual: true
    )
    series.recurring_occurrences.delete_all
    series.recurring_occurrences.create!(family: family, original_due_on: today + 5, due_on: today + 5, currency: "USD")

    get "/api/v1/accounts/#{account.id}/forecast", headers: api_headers(@api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "default", body["horizon"]
    assert body["shortfall"]
    assert_equal(-150, body["low_balance"]["amount"].to_d)
    assert_equal (today + 4).iso8601, body["top_up_by"]
    assert_equal [ "Rent" ], body["events"].map { |event| event["name"] }
  end

  test "forecast adds interest payments only when asked" do
    account = accounts(:depository)
    account.update!(balance: 1000, interest_payout_frequency: "daily")
    account.interest_rates.create!(effective_from: 1.year.ago.to_date, rate: 3.65)
    account.family.recurring_transactions.destroy_all

    get "/api/v1/accounts/#{account.id}/forecast", headers: api_headers(@api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body.key?("interest_payments")
    assert body["events"].none? { |event| event["kind"] == "interest" }
    assert_equal 1000, body["ending_balance"]["amount"].to_d

    get "/api/v1/accounts/#{account.id}/forecast", params: { include_interest: true }, headers: api_headers(@api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert body["interest_payments"].any?
    assert body["events"].none? { |event| event["kind"] == "interest" }
    assert_operator body["ending_balance"]["amount"].to_d, :>, 1000
  end

  test "forecast accepts an end date and rejects bad ones" do
    account = accounts(:depository)
    today = Account.liquidity_today_for(account.family)

    get "/api/v1/accounts/#{account.id}/forecast", params: { until: (today + 60).iso8601 }, headers: api_headers(@api_key)
    assert_response :success
    assert_equal "custom", JSON.parse(response.body)["horizon"]

    get "/api/v1/accounts/#{account.id}/forecast", params: { until: "tomorrow" }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    get "/api/v1/accounts/#{account.id}/forecast", params: { until: (today + 400).iso8601 }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "forecast refuses accounts without available money and other families' accounts" do
    get "/api/v1/accounts/#{accounts(:credit_card).id}/forecast", headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    get "/api/v1/accounts/#{accounts(:depository).id}/forecast", headers: api_headers(@other_family_api_key)
    assert_response :not_found
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def money_cents(money)
      (money.amount * money.currency.minor_unit_conversion).round(0).to_i
    end

    def assert_nullable_equal(expected, actual)
      expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
    end
end
