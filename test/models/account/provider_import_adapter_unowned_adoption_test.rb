require "test_helper"

# Ensures an "unowned" composite row (no account_provider_id) is fully adopted
# by the importing provider: attributes are updated, external_id attached and
# account_provider_id set, without an insert that collides on the unique index.
class Account::ProviderImportAdapterUnownedAdoptionTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @adapter = Account::ProviderImportAdapter.new(@account)
    @security = securities(:aapl)
    @holding_date = Date.today - 4.days

    item = SimplefinItem.create!(family: families(:dylan_family), name: "SF Conn", access_url: "https://example.com/access")
    sfa = SimplefinAccount.create!(
      simplefin_item: item,
      name: "SF Invest",
      account_id: "sf_inv_unowned_claim",
      currency: "USD",
      account_type: "investment",
      current_balance: 1000
    )
    @account_provider = AccountProvider.create!(account: @account, provider: sfa)

    @existing_unowned = @account.holdings.create!(
      security: @security,
      date: @holding_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider_id: nil
    )
  end

  test "adopts unowned holding by updating attrs and provider ownership" do
    assert_no_difference "@account.holdings.count" do
      @result = import(quantity: 2, amount: 220, price: 110, external_id: "ext-unowned-1")
    end

    @existing_unowned.reload

    assert_equal 2, @existing_unowned.qty
    assert_equal 110, @existing_unowned.price
    assert_equal 220, @existing_unowned.amount
    assert_equal @account_provider.id, @existing_unowned.account_provider_id
    assert_equal "ext-unowned-1", @existing_unowned.external_id
    assert_equal @existing_unowned.id, @result.id

    # Idempotency: re-import should not create a duplicate and should return the same row
    assert_no_difference "@account.holdings.count" do
      again = import(quantity: 2, amount: 220, price: 110, external_id: "ext-unowned-1")
      assert_equal @existing_unowned.id, again.id
    end
  end

  test "adopts unowned holding without a failing insert against the unique index" do
    failed_statements = []
    callback = ->(*, payload) { failed_statements << payload[:sql] if payload[:exception] }

    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      import(quantity: 2, amount: 220, price: 110, external_id: "ext-unowned-no-insert")
    end

    assert_empty failed_statements
    assert_equal @existing_unowned.id, result.id
    assert_equal @account_provider.id, @existing_unowned.reload.account_provider_id
  end

  test "adopting an unowned holding still validates the provider values" do
    assert_raises(ActiveRecord::RecordInvalid) do
      import(quantity: -4, amount: -400, price: 100, external_id: "ext-unowned-negative")
    end

    assert_equal 1, @existing_unowned.reload.qty
  end

  test "adopting an unowned holding carries the previous day's remap forward" do
    chosen = securities(:msft)
    @account.holdings.create!(
      security: chosen,
      provider_security: @security,
      security_locked: true,
      date: @holding_date - 1.day,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider_id: @account_provider.id,
      external_id: "ext-previous-day"
    )

    result = import(quantity: 2, amount: 220, price: 110, external_id: "ext-unowned-remap")

    assert_equal @existing_unowned.id, result.id
    @existing_unowned.reload
    assert_equal chosen, @existing_unowned.security
    assert_equal @security.id, @existing_unowned.provider_security_id
    assert @existing_unowned.security_locked?
  end

  test "adopting an unowned holding keeps its own locked cost basis over the previous day's" do
    @account.holdings.create!(
      security: @security,
      date: @holding_date - 1.day,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      cost_basis: 42,
      cost_basis_source: "manual",
      cost_basis_locked: true,
      account_provider_id: @account_provider.id,
      external_id: "ext-previous-day"
    )
    @existing_unowned.update!(cost_basis: 77, cost_basis_source: "manual", cost_basis_locked: true)

    import(quantity: 2, amount: 220, price: 110, external_id: "ext-unowned-own-lock")

    @existing_unowned.reload
    assert_equal 77, @existing_unowned.cost_basis
    assert_equal @account_provider.id, @existing_unowned.account_provider_id
  end

  private

    def import(quantity:, amount:, price:, external_id:)
      @adapter.import_holding(
        security: @security,
        quantity: quantity,
        amount: amount,
        currency: "USD",
        date: @holding_date,
        price: price,
        cost_basis: nil,
        external_id: external_id,
        source: "simplefin",
        account_provider_id: @account_provider.id,
        delete_future_holdings: false
      )
    end
end
