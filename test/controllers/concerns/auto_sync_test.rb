require "test_helper"

class AutoSyncTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family

    # Start fresh
    Sync.destroy_all
  end

  # The former `skip "AutoSync functionality temporarily disabled"` lines were stale; these tests pass on main without them.
  test "auto-syncs family if hasn't synced" do
    assert_difference "Sync.count", 1 do
      get root_path
    end
  end

  test "auto-syncs family if hasn't synced in last 24 hours" do
    # If request comes in at beginning of day, but last sync was 1 hour ago ("yesterday"), we still sync
    travel_to Time.current.beginning_of_day
    last_sync_datetime = 1.hour.ago

    Sync.create!(syncable: @family, created_at: last_sync_datetime, status: "completed")

    assert_difference "Sync.count", 1 do
      get root_path
    end
  end

  test "does not auto-sync if family has synced today already" do
    travel_to Time.current.end_of_day

    last_created_sync_at = 23.hours.ago

    Sync.create!(syncable: @family, created_at: last_created_sync_at, status: "completed")

    assert_no_difference "Sync.count" do
      get root_path
    end
  end

  test "does not auto-sync if preference is disabled" do
    @family.update!(auto_sync_on_login: false)

    assert_no_difference "Sync.count" do
      get root_path
    end
  end

  test "does not auto-sync on turbo-frame requests" do
    assert_no_difference "Sync.count" do
      get root_path, headers: { "Turbo-Frame" => "sparkline" }
    end
  end

  test "does not auto-sync on XHR requests" do
    assert_no_difference "Sync.count" do
      get root_path, xhr: true
    end
  end

  test "does not auto-sync on JSON requests" do
    assert_no_difference "Sync.count" do
      get root_path, headers: { "Accept" => "application/json" }
    end
  end

  test "does not auto-sync on Turbo prefetch requests" do
    [ "X-Sec-Purpose", "Sec-Purpose", "Purpose" ].each do |header|
      assert_no_difference "Sync.count", "#{header} prefetch should not auto-sync" do
        get root_path, headers: { header => "prefetch" }
      end
    end
  end

  test "concurrent first requests of the day enqueue sync and Plaid refresh only once" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    # Stubbed so no Sync row is created; the staleness check alone would let every request through.
    Family.any_instance.expects(:request_plaid_transactions_refreshes_later).with(source: "AutoSync").once
    Family.any_instance.expects(:sync_later).once

    3.times { get root_path }
  end

  test "releases the daily auto-sync claim when enqueueing the sync fails" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Family.any_instance.stubs(:request_plaid_transactions_refreshes_later)
    Family.any_instance.stubs(:sync_later).raises(RuntimeError, "enqueue failed")

    assert_raises(RuntimeError) { get root_path }

    Family.any_instance.expects(:sync_later).once
    get root_path
  end

  test "still auto-syncs when the cache backend fails to record the daily claim" do
    Rails.cache.stubs(:write).returns(false)
    Rails.cache.stubs(:exist?).returns(false)
    Family.any_instance.expects(:request_plaid_transactions_refreshes_later).with(source: "AutoSync").once
    Family.any_instance.expects(:sync_later).once

    get root_path
  end

  test "login-triggered sync requests Plaid refresh before syncing family" do
    controller_class = Class.new do
      def self.before_action(*) = nil

      include AutoSync

      def run_sync_family
        sync_family
      end
    end

    Current.stubs(:family).returns(@family)
    sequence = sequence("login-triggered sync")
    @family.expects(:request_plaid_transactions_refreshes_later).with(source: "AutoSync").in_sequence(sequence)
    @family.expects(:sync_later).in_sequence(sequence)

    controller_class.new.run_sync_family
  end

  test "login-triggered sync continues when Plaid refresh orchestration cannot be enqueued" do
    controller_class = Class.new do
      def self.before_action(*) = nil

      include AutoSync

      def run_sync_family
        sync_family
      end
    end

    Current.stubs(:family).returns(@family)
    PlaidTransactionsRefreshAllJob.stubs(:perform_later).raises(RedisClient::Error, "Redis unavailable")
    @family.expects(:sync_later).once

    controller_class.new.run_sync_family
  end
end
