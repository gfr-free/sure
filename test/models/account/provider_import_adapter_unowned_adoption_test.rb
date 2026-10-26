require "test_helper"

# Ensures an "unowned" composite row (no account_provider_id) is fully adopted on
# first collision: attributes are updated, external_id attached, and
# account_provider_id set to the importing provider.
class Account::ProviderImportAdapterUnownedAdoptionTest < ActiveSupport::TestCase
  test "adopts unowned holding on unique-index collision by updating attrs and provider ownership" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create a SimpleFin provider for this account (the importer)
    item = SimplefinItem.create!(family: families(:dylan_family), name: "SF Conn", access_url: "https://example.com/access")
    sfa = SimplefinAccount.create!(
      simplefin_item: item,
      name: "SF Invest",
      account_id: "sf_inv_unowned_claim",
      currency: "USD",
      account_type: "investment",
      current_balance: 1000
    )
    ap = AccountProvider.create!(account: investment_account, provider: sfa)

    holding_date = Date.today - 4.days

    # Existing composite row without provider ownership (unowned)
    existing_unowned = investment_account.holdings.create!(
      security: security,
      date: holding_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider_id: nil
    )

    # Import for SimpleFin with an external_id that will collide on composite key
    # Adapter should NOT create a new row, but should update the existing one:
    # - qty/price/amount/cost_basis updated
    # - external_id attached
    # - account_provider_id adopted to ap.id
    assert_no_difference "investment_account.holdings.count" do
      @result = adapter.import_holding(
        security: security,
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: holding_date,
        price: 110,
        cost_basis: nil,
        external_id: "ext-unowned-1",
        source: "simplefin",
        account_provider_id: ap.id,
        delete_future_holdings: false
      )
    end

    existing_unowned.reload

    # Attributes updated
    assert_equal 2, existing_unowned.qty
    assert_equal 110, existing_unowned.price
    assert_equal 220, existing_unowned.amount

    # Ownership and external_id adopted
    assert_equal ap.id, existing_unowned.account_provider_id
    assert_equal "ext-unowned-1", existing_unowned.external_id

    # Adapter returns the same row
    assert_equal existing_unowned.id, @result.id

    # Idempotency: re-import should not create a duplicate and should return the same row
    assert_no_difference "investment_account.holdings.count" do
      again = adapter.import_holding(
        security: security,
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: holding_date,
        price: 110,
        cost_basis: nil,
        external_id: "ext-unowned-1",
        source: "simplefin",
        account_provider_id: ap.id,
        delete_future_holdings: false
      )
      assert_equal existing_unowned.id, again.id
    end
  end

  test "adopting an unowned holding keeps the user's cost basis lock and security" do
    investment_account = accounts(:investment)
    ap = simplefin_provider_for(investment_account, "sf_inv_locked_adopt")
    holding_date = Date.today - 4.days

    existing_unowned = investment_account.holdings.create!(
      security: securities(:aapl),
      date: holding_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      cost_basis: 80,
      cost_basis_source: "manual",
      cost_basis_locked: true,
      security_locked: true,
      account_provider_id: nil
    )

    Account::ProviderImportAdapter.new(investment_account).import_holding(
      security: securities(:aapl),
      quantity: 2,
      amount: 220,
      currency: "USD",
      date: holding_date,
      price: 110,
      cost_basis: 95,
      external_id: "ext-locked-1",
      source: "simplefin",
      account_provider_id: ap.id
    )

    existing_unowned.reload
    assert_equal 2, existing_unowned.qty
    assert_equal ap.id, existing_unowned.account_provider_id
    assert_equal 80, existing_unowned.cost_basis
    assert_equal "manual", existing_unowned.cost_basis_source
    assert existing_unowned.cost_basis_locked?
    assert existing_unowned.security_locked?
    assert_equal securities(:aapl), existing_unowned.security
  end

  test "a failed adoption update is logged and leaves the import transaction usable" do
    investment_account = accounts(:investment)
    ap = simplefin_provider_for(investment_account, "sf_inv_failed_adopt")
    holding_date = Date.today - 4.days

    # The provider's row was first resolved to MSFT; this sync resolves the
    # same external_id to AAPL, where a calculated row already sits.
    provider_row = investment_account.holdings.create!(
      security: securities(:msft),
      date: holding_date,
      qty: 2,
      price: 50,
      amount: 100,
      currency: "USD",
      external_id: "ext-moved-1",
      account_provider_id: ap.id
    )
    calculated_row = investment_account.holdings.create!(
      security: securities(:aapl),
      date: holding_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider_id: nil
    )

    # Attaching the external_id to the calculated row collides with the
    # provider row, which still holds it.
    assert_difference -> { DebugLogEntry.where(category: "provider_sync_warning", account_provider_id: ap.id).count }, 1 do
      @result = Account::ProviderImportAdapter.new(investment_account).import_holding(
        security: securities(:aapl),
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: holding_date,
        price: 110,
        external_id: "ext-moved-1",
        source: "simplefin",
        account_provider_id: ap.id
      )
    end

    assert_equal calculated_row.id, @result.id
    assert_equal 1, calculated_row.reload.qty
    assert_nil calculated_row.account_provider_id
    assert_equal securities(:msft), provider_row.reload.security

    log = DebugLogEntry.where(category: "provider_sync_warning", account_provider_id: ap.id).last
    assert_equal "simplefin", log.provider_key
    assert_equal calculated_row.id, log.metadata["holding_id"]
  end

  private
    def simplefin_provider_for(account, upstream_id)
      item = SimplefinItem.create!(family: account.family, name: "SF Conn", access_url: "https://example.com/access")
      sfa = SimplefinAccount.create!(
        simplefin_item: item,
        name: "SF Invest",
        account_id: upstream_id,
        currency: "USD",
        account_type: "investment",
        current_balance: 1000
      )
      AccountProvider.create!(account: account, provider: sfa)
    end
end
