require "test_helper"

class Account::ReconciliationManagerTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @account = accounts(:investment)
    @manager = Account::ReconciliationManager.new(@account)
  end

  test "new reconciliation" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    result = @manager.reconcile_balance(balance: 1200, date: Date.current)

    assert_equal 1200, result.new_balance
    assert_equal 700, result.new_cash_balance # Non cash stays the same since user is valuing the entire account balance
    assert_equal 1000, result.old_balance
    assert_equal 500, result.old_cash_balance
    assert_equal true, result.success?
  end

  test "updates existing reconciliation without date change" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    # Existing reconciliation entry
    existing_entry = @account.entries.create!(name: "Test", amount: 1000, date: Date.current, entryable: Valuation.new(kind: "reconciliation"), currency: @account.currency)

    result = @manager.reconcile_balance(balance: 1200, date: Date.current, existing_valuation_entry: existing_entry)

    assert_equal 1200, result.new_balance
    assert_equal 700, result.new_cash_balance # Non cash stays the same since user is valuing the entire account balance
    assert_equal 1000, result.old_balance
    assert_equal 500, result.old_cash_balance
    assert_equal true, result.success?
  end

  test "updates existing reconciliation with date and amount change" do
    create_balance(account: @account, date: 5.days.ago, balance: 1000, cash_balance: 500)
    create_balance(account: @account, date: Date.current, balance: 1200, cash_balance: 700)

    # Existing reconciliation entry (5 days ago)
    existing_entry = @account.entries.create!(name: "Test", amount: 1000, date: 5.days.ago, entryable: Valuation.new(kind: "reconciliation"), currency: @account.currency)

    # Should update and change date for existing entry; not create a new one
    assert_no_difference "Valuation.count" do
      # "Update valuation from 5 days ago to today, set balance from 1000 to 1500"
      result = @manager.reconcile_balance(balance: 1500, date: Date.current, existing_valuation_entry: existing_entry)

      assert_equal true, result.success?

      # Reconciliation
      assert_equal 1500, result.new_balance # Equal to new valuation amount
      assert_equal 1000, result.new_cash_balance # Get non-cash balance today (1200 - 700 = 500). Then subtract this from new valuation (1500 - 500 = 1000)

      # Prior valuation
      assert_equal 1000, result.old_balance # This is the balance from the old valuation, NOT the date we're reconciling to
      assert_equal 500, result.old_cash_balance
    end
  end

  test "handles date conflicts" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 1000)

    # Existing reconciliation entry
    @account.entries.create!(
      name: "Test",
      amount: 1000,
      date: Date.current,
      entryable: Valuation.new(kind: "reconciliation"),
      currency: @account.currency
    )

    # Doesn't pass existing_valuation_entry, but reconciliation manager should recognize its the same date and update the existing entry
    assert_no_difference "Valuation.count" do
      result = @manager.reconcile_balance(balance: 1200, date: Date.current)

      assert result.success?
      assert_equal 1200, result.new_balance
    end
  end

  test "dry run does not persist account" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    assert_no_difference "Valuation.count" do
      @manager.reconcile_balance(balance: 1200, date: Date.current, dry_run: true)
    end

    assert_difference "Valuation.count", 1 do
      @manager.reconcile_balance(balance: 1200, date: Date.current)
    end
  end

  test "reconciliation matches an open manual_save pledge by contribution delta" do
    account = accounts(:depository)
    manager = Account::ReconciliationManager.new(account)
    create_balance(account: account, date: Date.current, balance: 2000, cash_balance: 2000)

    pledge = goal_pledges(:open_transfer).goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    result = manager.reconcile_balance(balance: 2150, date: Date.current)

    assert result.success?
    assert pledge.reload.status_matched?
  end

  test "reconciliation to the same balance leaves manual_save pledges open" do
    account = accounts(:depository)
    manager = Account::ReconciliationManager.new(account)
    create_balance(account: account, date: Date.current, balance: 2000, cash_balance: 2000)

    pledge = goal_pledges(:open_transfer).goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    result = manager.reconcile_balance(balance: 2000, date: Date.current)

    assert result.success?
    assert_not pledge.reload.status_matched?
  end

  test "second same-day reconcile derives its delta from the valuation it updates, not the stale balance row" do
    account = accounts(:depository)
    manager = Account::ReconciliationManager.new(account)
    create_balance(account: account, date: Date.current, balance: 2000, cash_balance: 2000)

    goal = goal_pledges(:open_transfer).goal
    first_pledge = goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    assert manager.reconcile_balance(balance: 2150, date: Date.current).success?
    assert first_pledge.reload.status_matched?

    # The post-reconcile balance sync is async and hasn't run, so the
    # balances row still says $2,000. The second save of $150 (2150 → 2300)
    # must not be read as a $300 contribution off that stale row — that
    # would wrongly close the larger pledge, and a wrong match never
    # self-heals.
    oversized_pledge = goal.goal_pledges.create!(
      account: account,
      amount: 300,
      currency: "USD",
      kind: "manual_save"
    )
    second_pledge = goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    assert manager.reconcile_balance(balance: 2300, date: Date.current).success?

    assert_not oversized_pledge.reload.status_matched?
    assert second_pledge.reload.status_matched?
  end

  # -------------------------------------------------------------------------------------------------
  # Linked accounts
  #
  # Balances of a linked account are calculated backwards from its current anchor, and the displayed
  # balance is the anchor's. A valuation from the anchor's date up to today becomes the anchor.
  # -------------------------------------------------------------------------------------------------

  test "a valuation after a linked account's anchor becomes the current balance" do
    account = linked_account
    old_anchor = create_current_anchor(account, amount: 2945.75, date: 1.day.ago.to_date)

    result = Account::ReconciliationManager.new(account).reconcile_balance(balance: 3007.83, date: Date.current)

    assert result.success?
    assert_equal 3007.83, account.reload.balance

    anchor = account.valuations.current_anchor.sole
    assert_equal Date.current, anchor.entry.date
    assert_equal 3007.83, anchor.entry.amount
    assert old_anchor.reload.entryable.reconciliation?, "the previous anchor stays behind as a waypoint"
    assert_equal 2945.75, old_anchor.amount

    Balance::Materializer.new(account, strategy: :reverse).materialize_balances
    assert_equal 3007.83, account.balances.find_by!(date: Date.current).end_balance
    assert_equal 2945.75, account.balances.find_by!(date: 1.day.ago.to_date).end_balance
  end

  test "a valuation on the anchor's date updates a linked account's displayed balance" do
    account = linked_account
    anchor = create_current_anchor(account, amount: 9070.25, date: Date.current)

    assert_no_difference -> { account.entries.count } do
      result = Account::ReconciliationManager.new(account).reconcile_balance(balance: 9073.32, date: Date.current)
      assert result.success?
    end

    assert_equal 9073.32, anchor.reload.amount
    assert anchor.entryable.current_anchor?
    assert_equal 9073.32, account.reload.balance
  end

  test "a valuation before a linked account's anchor stays a waypoint" do
    account = linked_account
    anchor = create_current_anchor(account, amount: 5000, date: Date.current)

    result = Account::ReconciliationManager.new(account).reconcile_balance(balance: 4000, date: 3.days.ago.to_date)

    assert result.success?
    assert_equal 5000, account.reload.balance
    assert_equal anchor, account.valuations.current_anchor.sole.entry
    assert account.entries.valuations.find_by!(date: 3.days.ago.to_date).entryable.reconciliation?
  end

  test "a future valuation does not move a linked account's anchor" do
    account = linked_account
    anchor = create_current_anchor(account, amount: 5000, date: Date.current)

    Account::ReconciliationManager.new(account).reconcile_balance(balance: 6000, date: 2.days.from_now.to_date)

    assert_equal 5000, account.reload.balance
    assert_equal anchor, account.valuations.current_anchor.sole.entry
  end

  test "a valuation on a linked account's opening anchor date keeps the opening anchor" do
    account = linked_account
    opening = account.entries.create!(
      name: Valuation.build_opening_anchor_name(account.accountable_type),
      amount: 1000,
      date: Date.current,
      currency: account.currency,
      entryable: Valuation.new(kind: "opening_anchor")
    )

    Account::ReconciliationManager.new(account).reconcile_balance(balance: 1200, date: Date.current, existing_valuation_entry: opening)

    assert opening.reload.entryable.opening_anchor?
    assert_empty account.valuations.current_anchor
  end

  test "a linked account with unsaved changes can still take a valuation as its anchor" do
    account = linked_account
    create_current_anchor(account, amount: 4500, date: 1.day.ago.to_date)
    account.name = "Renamed, not yet saved"

    result = Account::ReconciliationManager.new(account).reconcile_balance(balance: 4750, date: Date.current)

    assert result.success?, result.error_message
    assert_equal 4750, account.reload.balance
  end

  test "the next provider reading replaces a valuation that became the anchor" do
    account = linked_account
    create_current_anchor(account, amount: 2945.75, date: 1.day.ago.to_date)
    Account::ReconciliationManager.new(account).reconcile_balance(balance: 3007.83, date: Date.current)

    account.set_current_balance(3010.00, schedule_sync: false)

    assert_equal 3010.00, account.reload.balance
    assert_equal 3010.00, account.valuations.current_anchor.sole.entry.amount
  end

  private
    def linked_account
      account = accounts(:connected)
      account.account_providers.find_or_create_by!(provider_type: "PlaidAccount", provider_id: plaid_accounts(:one).id)
      account.entries.destroy_all
      account
    end

    def create_current_anchor(account, amount:, date:)
      account.entries.create!(
        name: Valuation.build_current_anchor_name(account.accountable_type),
        amount: amount,
        date: date,
        currency: account.currency,
        entryable: Valuation.new(kind: "current_anchor")
      )
    end
end
