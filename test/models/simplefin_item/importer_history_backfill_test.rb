require "test_helper"

class SimplefinItem::ImporterHistoryBackfillTest < ActiveSupport::TestCase
  # Answers every request with the same accounts; records the requested windows.
  class FakeProvider
    attr_reader :requests

    def initialize(accounts)
      @accounts = accounts
      @requests = []
    end

    def get_accounts(_access_url, start_date: nil, end_date: nil, pending: nil)
      @requests << { start_date: start_date, end_date: end_date }
      { accounts: @accounts.map(&:deep_dup), errors: [] }
    end
  end

  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN Backfill Test",
      access_url: "https://example.com/access"
    )
    @item.syncs.create!(status: :completed, completed_at: 1.day.ago)

    @synced_sfa = create_simplefin_account("sf_synced", "Checking")
    @synced_sfa.update!(
      raw_transactions_payload: [ { id: "t1", amount: "-5", posted: 3.days.ago.to_i } ],
      history_backfilled_at: 1.week.ago
    )
    AccountProvider.create!(account: accounts(:depository), provider: @synced_sfa)
  end

  test "a newly linked account next to synced siblings triggers the chunked history backfill" do
    new_sfa = create_simplefin_account("sf_relinked", "Card")
    AccountProvider.create!(account: accounts(:credit_card), provider: new_sfa)

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
    importer.expects(:import_with_chunked_history).once
    importer.expects(:import_regular_sync).never

    importer.import
  end

  test "items whose linked accounts were all backfilled use the regular window" do
    importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
    importer.expects(:import_with_chunked_history).never
    importer.expects(:import_regular_sync).once

    importer.import
  end

  test "unlinked accounts without a backfill do not trigger the chunked history" do
    create_simplefin_account("sf_unlinked", "Skipped")

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
    importer.expects(:import_with_chunked_history).never
    importer.expects(:import_regular_sync).once

    importer.import
  end

  test "the backfill imports the new account's history and marks every account of the item" do
    new_sfa = create_simplefin_account("sf_relinked", "Card")
    AccountProvider.create!(account: accounts(:credit_card), provider: new_sfa)
    unlinked_sfa = create_simplefin_account("sf_unlinked", "Skipped")
    missing_sfa = create_simplefin_account("sf_missing", "Missing")
    accounts(:investment).update!(simplefin_account_id: missing_sfa.id)

    provider = FakeProvider.new([
      account_payload("sf_synced", "Checking"),
      account_payload("sf_relinked", "Card", transactions: [
        { id: "c1", amount: "-12.50", posted: 40.days.ago.to_i, description: "Coffee" }
      ]),
      account_payload("sf_unlinked", "Skipped")
    ])

    SimplefinItem::Importer.new(@item, simplefin_provider: provider).import

    assert provider.requests.any? { |r| r[:start_date].present? && r[:end_date].present? }, "expected dated history windows"
    assert_equal [ "c1" ], new_sfa.reload.raw_transactions_payload.map { |t| t["id"] }
    assert_not_nil new_sfa.history_backfilled_at
    assert_not_nil unlinked_sfa.reload.history_backfilled_at
    assert_not_nil missing_sfa.reload.history_backfilled_at, "an account the walk could not fetch must not force the walk on every sync"

    importer = SimplefinItem::Importer.new(@item.reload, simplefin_provider: provider)
    importer.expects(:import_with_chunked_history).never
    importer.expects(:import_regular_sync).once

    importer.import
  end

  test "accounts linked after the first sync of a new connection do not repeat the walk" do
    @item.syncs.destroy_all
    onboarding_sfa = create_simplefin_account("sf_onboarding", "Savings")
    provider = FakeProvider.new([
      account_payload("sf_synced", "Checking"),
      account_payload("sf_onboarding", "Savings")
    ])

    SimplefinItem::Importer.new(@item, simplefin_provider: provider).import
    @item.syncs.create!(status: :completed, completed_at: Time.current)
    AccountProvider.create!(account: accounts(:credit_card), provider: onboarding_sfa)

    importer = SimplefinItem::Importer.new(@item.reload, simplefin_provider: provider)
    importer.expects(:import_with_chunked_history).never
    importer.expects(:import_regular_sync).once

    importer.import
  end

  test "a rate-limited walk leaves the accounts unmarked so the next sync retries" do
    new_sfa = create_simplefin_account("sf_relinked", "Card")
    AccountProvider.create!(account: accounts(:credit_card), provider: new_sfa)
    importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
    importer.stubs(:perform_account_discovery)
    importer.stubs(:fetch_accounts_data).raises(SimplefinItem::Importer::RateLimitedError)

    assert_raises(SimplefinItem::Importer::RateLimitedError) { importer.import }
    assert_nil new_sfa.reload.history_backfilled_at
  end

  test "a linked account the backfill found no transactions for is not backfilled again" do
    quiet_sfa = create_simplefin_account("sf_quiet", "Dormant savings")
    AccountProvider.create!(account: accounts(:credit_card), provider: quiet_sfa)

    provider = FakeProvider.new([
      account_payload("sf_synced", "Checking"),
      account_payload("sf_quiet", "Dormant savings")
    ])

    SimplefinItem::Importer.new(@item, simplefin_provider: provider).import

    assert quiet_sfa.reload.raw_transactions_payload.blank?
    assert_not_nil quiet_sfa.history_backfilled_at

    importer = SimplefinItem::Importer.new(@item.reload, simplefin_provider: provider)
    importer.expects(:import_with_chunked_history).never
    importer.expects(:import_regular_sync).once

    importer.import
  end

  private

    def create_simplefin_account(account_id, name)
      @item.simplefin_accounts.create!(
        name: name,
        account_id: account_id,
        account_type: "checking",
        currency: "USD",
        current_balance: 100
      )
    end

    def account_payload(id, name, transactions: [])
      {
        id: id,
        name: name,
        currency: "USD",
        balance: "100.00",
        "available-balance": "100.00",
        "balance-date": Time.current.to_i,
        transactions: transactions,
        holdings: []
      }
    end
end
