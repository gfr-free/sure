require "test_helper"

class Family::SyncCompleteEventTest < ActiveSupport::TestCase
  fixtures :families, :accounts, :plaid_items

  setup do
    @family = families(:dylan_family)
    Sync.where(status: %w[pending syncing]).update_all(status: "completed")
  end

  test "broadcast replaces both the sync toast and the accounts page's own sync controls" do
    expect_toast(@family).once
    expect_sync_controls(@family).once

    Family::SyncCompleteEvent.new(@family).broadcast
  end

  test "holds back the toast while another sync of the same family is still running" do
    plaid_items(:one).syncs.create!(status: "syncing")

    expect_toast(@family).never
    expect_sync_controls(@family).once

    Family::SyncCompleteEvent.new(@family).broadcast
  end

  test "holds back the toast while a manual account or the family sync itself is still running" do
    [ accounts(:depository), @family ].each do |syncable|
      sync = syncable.syncs.create!(status: "pending")

      expect_toast(@family).never
      expect_sync_controls(@family).once
      Family::SyncCompleteEvent.new(@family).broadcast

      sync.update!(status: "completed")
    end
  end

  test "sends the toast once the last running sync has finished" do
    sync = plaid_items(:one).syncs.create!(status: "syncing")
    sync.update!(status: "completed")

    expect_toast(@family).once
    expect_sync_controls(@family).once

    Family::SyncCompleteEvent.new(@family).broadcast
  end

  test "ignores syncs of other families, cancelled syncs and syncs hung past the visibility window" do
    other_family_account = accounts(:depository).dup.tap do |account|
      account.family = families(:empty)
      account.save!(validate: false)
    end
    other_family_account.syncs.create!(status: "syncing")
    plaid_items(:one).syncs.create!(status: "syncing", cancel_requested_at: Time.current)
    plaid_items(:one).syncs.create!(status: "syncing", created_at: (Sync::VISIBLE_FOR + 1.minute).ago)

    expect_toast(@family).once
    expect_sync_controls(@family).once

    Family::SyncCompleteEvent.new(@family).broadcast
  end

  test "checks for running syncs only after the finalizing transaction commits" do
    other_sync = plaid_items(:one).syncs.create!(status: "syncing")

    expect_toast(@family).once
    expect_sync_controls(@family).once

    ActiveRecord::Base.transaction(requires_new: true) do
      Family::SyncCompleteEvent.new(@family).broadcast
      other_sync.update!(status: "completed")
    end
  end

  test "syncing two manual accounts refreshes the page once, after the last one finishes" do
    first_sync = accounts(:depository).syncs.create!
    second_sync = accounts(:credit_card).syncs.create!

    Account.any_instance.stubs(:perform_sync)
    Account.any_instance.stubs(:perform_post_sync)
    Account.any_instance.stubs(:broadcast_replace_to)
    Account.any_instance.stubs(:broadcast_refresh)
    Family.any_instance.stubs(:broadcast_replace_to).with(anything, has_entry(target: "accounts-sync-controls"))

    toasts = sequence("toasts")
    Family.any_instance.expects(:broadcast_replace_to)
      .with(anything, has_entry(target: "sync-toast")).never.in_sequence(toasts)
    first_sync.perform
    assert_equal "completed", first_sync.reload.status

    Family.any_instance.expects(:broadcast_replace_to)
      .with(anything, has_entry(target: "sync-toast")).once.in_sequence(toasts)
    second_sync.perform
    assert_equal "completed", second_sync.reload.status
  end

  test "cancelling the sync that held back the toast sends it" do
    held_back_sync = plaid_items(:one).syncs.create!(status: "pending")

    Family.any_instance.expects(:broadcast_replace_to)
      .with(anything, has_entry(target: "sync-toast")).once

    assert held_back_sync.request_cancel!
    assert_equal "stale", held_back_sync.reload.status
  end

  test "sweeping up long-abandoned syncs does not send the toast" do
    plaid_items(:one).syncs.create!(status: "syncing", created_at: (Sync::STALE_AFTER + 1.hour).ago)

    Family.any_instance.expects(:broadcast_replace_to)
      .with(anything, has_entry(target: "sync-toast")).never

    Sync.clean
  end

  private
    def expect_toast(family)
      family.expects(:broadcast_replace_to).with(
        family,
        target: "sync-toast",
        partial: "shared/notifications/sync_toast"
      )
    end

    def expect_sync_controls(family)
      family.expects(:broadcast_replace_to).with(
        family,
        target: "accounts-sync-controls",
        partial: "accounts/sync_controls",
        locals: { family: family }
      )
    end
end
