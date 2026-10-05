require "test_helper"

class Assistant::Function::GetAccountForecastTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
    @account = accounts(:depository)
    @account.update!(balance: 500)
    @today = Account.liquidity_today_for(@family)
  end

  test "returns the forecast with its expected payments" do
    series = @family.recurring_transactions.create!(
      name: "Rent", account: @account, amount: 650, currency: "USD", bill_type: "bill",
      expected_day_of_month: 15, last_occurrence_date: @today, next_expected_date: @today + 30,
      status: "active", manual: true
    )
    series.recurring_occurrences.delete_all
    series.recurring_occurrences.create!(family: @family, original_due_on: @today + 5, due_on: @today + 5, currency: "USD")

    result = call_tool("account_id" => @account.id)

    assert result[:shortfall]
    assert_equal (@today + 5).iso8601, result[:low_on]
    assert_equal [ "Rent" ], result[:expected_payments].map { |payment| payment[:name] }
  end

  test "rejects accounts that cannot be forecast and bad input" do
    assert_equal "not_forecastable", call_tool("account_id" => accounts(:credit_card).id)[:error]
    assert_equal "invalid_account_id", call_tool("account_id" => "nope")[:error]
    assert_equal "account_not_found", call_tool("account_id" => SecureRandom.uuid)[:error]
    assert_equal "invalid_until", call_tool("account_id" => @account.id, "until" => "soon")[:error]
  end

  test "is offered only to preview users" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    assert_not_includes Assistant.function_classes(@user), Assistant::Function::GetAccountForecast

    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    assert_includes Assistant.function_classes(@user), Assistant::Function::GetAccountForecast
  end

  private
    def call_tool(params)
      Assistant::Function::GetAccountForecast.new(@user).call(params)
    end
end
