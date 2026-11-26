require "test_helper"

class Insight::Generators::ConnectionAttentionGeneratorTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 11, 26, 12)

    @family = families(:dylan_family)
    # Shared with family_member, so a card about it may show in the feed.
    @account = accounts(:depository)
    @item = trade_republic_items(:configured_item)
    @item.update!(session_expires_at: 1.hour.from_now)
    @account.account_providers.create!(provider: trade_republic_accounts(:main_account))
    Sync.where(syncable_type: "TradeRepublicItem").delete_all
  end

  test "a connection that needs a new sign-in is reported at once" do
    @item.update!(session_expires_at: 1.minute.ago)
    sync(:completed, 2.hours.ago)

    insight = insight_for(@item)

    assert_equal "connection_needs_attention", insight.insight_type
    assert_equal "high", insight.priority
    assert_equal "connection_needs_attention:TradeRepublicItem:#{@item.id}:reconnect", insight.dedup_key
    assert_equal "reconnect", insight.metadata[:reason]
    assert_equal [ @account.id ], insight.metadata[:account_ids]
    assert_equal false, insight.metadata[:reminder]
    assert_equal "Your connection to #{@item.institution_display_name} needs to be renewed", insight.title
    assert_not insight.metadata.key?(:account_id), "a connection names its accounts in account_ids only"
  end

  test "a failed sync is not reported while the last good one is less than a day old" do
    sync(:completed, 20.hours.ago)
    sync(:failed, 1.hour.ago)

    assert_nil insight_for(@item)
  end

  test "syncs that keep failing for more than a day are reported with the last good date" do
    sync(:completed, 30.hours.ago)
    sync(:failed, 26.hours.ago)
    sync(:failed, 2.hours.ago)

    insight = insight_for(@item)

    assert_equal "failing", insight.metadata[:reason]
    assert_equal 30.hours.ago.to_date.iso8601, insight.metadata[:last_success_on]
    assert_equal I18n.l(30.hours.ago.to_date, format: :long), insight.facts[:since]
    assert_equal false, insight.metadata[:reminder]
  end

  test "a stale sync counts as a failure" do
    sync(:completed, 3.days.ago)
    sync(:stale, 2.days.ago)

    assert_equal "failing", insight_for(@item).metadata[:reason]
  end

  test "a sync in progress does not hide an ongoing failure" do
    sync(:completed, 3.days.ago)
    sync(:failed, 2.days.ago)
    sync(:syncing, 1.minute.ago)

    assert_equal "failing", insight_for(@item).metadata[:reason]
  end

  test "a sync that went through clears the failure" do
    sync(:failed, 3.days.ago)
    sync(:completed, 1.hour.ago)

    assert_nil insight_for(@item)
  end

  test "the reminder turns on once the problem has lasted three days" do
    @item.update!(session_expires_at: 4.days.ago)
    sync(:completed, 5.days.ago)
    sync(:failed, 4.days.ago)

    assert_equal true, insight_for(@item).metadata[:reminder]
  end

  test "the failure episode starts when the failures became reportable" do
    sync(:completed, 3.days.ago)
    sync(:failed, 2.days.ago - 1.hour)

    # Reportable a day after the last good sync, so two days before now.
    assert_equal false, insight_for(@item).metadata[:reminder]

    travel 1.day + 1.minute
    assert_equal true, insight_for(@item).metadata[:reminder]
  end

  test "an Enable Banking consent ending within a week is reported" do
    item = enable_banking_item(session_expires_at: 5.days.from_now)

    insight = insight_for(item)

    assert_equal "expiring", insight.metadata[:reason]
    assert_equal 5.days.from_now.to_date.iso8601, insight.metadata[:expires_on]
    assert_equal I18n.l(5.days.from_now.to_date, format: :long), insight.facts[:expires_on]
  end

  test "an Enable Banking consent ending later is not reported" do
    item = enable_banking_item(session_expires_at: 8.days.from_now)

    assert_nil insight_for(item)
  end

  test "a connection without linked accounts is not reported" do
    @account.account_providers.destroy_all
    @item.update!(session_expires_at: 1.minute.ago)

    assert_nil insight_for(@item)
  end

  test "a connection scheduled for deletion is not reported" do
    @item.update!(session_expires_at: 1.minute.ago, scheduled_for_deletion: true)

    assert_nil insight_for(@item)
  end

  test "a legacy Plaid link counts as a linked account" do
    plaid_item = plaid_items(:one)
    plaid_item.update!(status: :requires_update)

    insight = insight_for(plaid_item)

    assert_equal [ accounts(:connected).id ], insight.metadata[:account_ids]
  end

  private
    def sync(status, at)
      Sync.create!(syncable: @item, status: status, created_at: at,
                   completed_at: (at if status == :completed), failed_at: (at if status == :failed))
    end

    def enable_banking_item(session_expires_at:)
      item = EnableBankingItem.create!(family: @family, name: "Test Bank", country_code: "FI", application_id: "app",
                                       client_certificate: "cert", session_id: "session", session_expires_at: session_expires_at)
      eb_account = item.enable_banking_accounts.create!(name: "Checking", uid: "eb_checking", currency: "EUR")
      accounts(:investment).account_providers.create!(provider: eb_account)
      Sync.create!(syncable: item, status: :completed, completed_at: 1.hour.ago)
      item
    end

    def insight_for(item)
      Insight::Generators::ConnectionAttentionGenerator.new(@family).generate
        .find { |insight| insight.metadata[:connection_id] == item.id }
    end
end
