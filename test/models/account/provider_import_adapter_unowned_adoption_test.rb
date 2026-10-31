require "test_helper"

# Ensures an "unowned" composite row (no account_provider_id) is adopted on
# first collision: attributes are updated, external_id attached, and
# account_provider_id set to the importing provider. A write that still fails
# is logged without breaking the surrounding sync transaction.
class Account::ProviderImportAdapterUnownedAdoptionTest < ActiveSupport::TestCase
  test "adopts unowned holding on unique-index collision by updating attrs and provider ownership" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    ap = simplefin_provider_for(investment_account, "sf_inv_unowned_claim")

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

  test "adopting an unowned holding keeps the user's cost basis lock" do
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
  end

  test "adopts the snapshot without the external_id another row still holds" do
    investment_account = accounts(:investment)
    ap = simplefin_provider_for(investment_account, "sf_inv_moved_security")
    holding_date = Date.today - 4.days

    # The provider's row was first resolved to MSFT; this sync resolves the
    # same external_id to AAPL, where a calculated row already sits.
    provider_row, calculated_row = create_moved_security_rows(investment_account, ap, holding_date)

    assert_no_difference -> { DebugLogEntry.where(category: "provider_sync_warning").count } do
      @result = import_moved_security(investment_account, ap, holding_date)
    end

    assert_equal calculated_row.id, @result.id
    calculated_row.reload
    assert_equal 2, calculated_row.qty
    assert_equal ap.id, calculated_row.account_provider_id
    assert_nil calculated_row.external_id
    assert_equal "ext-moved-1", provider_row.reload.external_id
  end

  test "a failed snapshot write is logged and leaves the import transaction usable" do
    investment_account = accounts(:investment)
    ap = simplefin_provider_for(investment_account, "sf_inv_failed_adopt")
    holding_date = Date.today - 4.days
    provider_row, calculated_row = create_moved_security_rows(investment_account, ap, holding_date)

    # A concurrent writer claims the external_id between the check and the write.
    adapter = Account::ProviderImportAdapter.new(investment_account)
    adapter.stubs(:external_id_taken?).returns(false)

    assert_difference -> { DebugLogEntry.where(category: "provider_sync_warning", account_provider_id: ap.id).count }, 1 do
      @result = import_moved_security(investment_account, ap, holding_date, adapter: adapter)
    end

    assert_equal calculated_row.id, @result.id
    assert_equal 1, @result.qty
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

    def create_moved_security_rows(account, account_provider, date)
      provider_row = account.holdings.create!(
        security: securities(:msft), date: date, qty: 2, price: 50, amount: 100, currency: "USD",
        external_id: "ext-moved-1", account_provider_id: account_provider.id
      )
      calculated_row = account.holdings.create!(
        security: securities(:aapl), date: date, qty: 1, price: 100, amount: 100, currency: "USD",
        account_provider_id: nil
      )
      [ provider_row, calculated_row ]
    end

    def import_moved_security(account, account_provider, date, adapter: Account::ProviderImportAdapter.new(account))
      adapter.import_holding(
        security: securities(:aapl),
        quantity: 2,
        amount: 220,
        currency: "USD",
        date: date,
        price: 110,
        external_id: "ext-moved-1",
        source: "simplefin",
        account_provider_id: account_provider.id
      )
    end
end
