require "test_helper"

class SyncJobTest < ActiveJob::TestCase
  test "sync is performed" do
    syncable = accounts(:depository)

    sync = syncable.syncs.create!(window_start_date: 2.days.ago.to_date)

    sync.expects(:perform).once

    SyncJob.perform_now(sync)
  end

  test "re-enqueues with the same arguments while another sync of the syncable runs" do
    sync = accounts(:depository).syncs.create!

    sync.expects(:perform).raises(Sync::ConcurrentSyncError)

    assert_enqueued_with(job: SyncJob, args: [ sync, { balances_only: true } ]) do
      SyncJob.perform_now(sync, balances_only: true)
    end
  end
end
