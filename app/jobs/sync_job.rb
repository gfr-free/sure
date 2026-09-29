class SyncJob < ApplicationJob
  queue_as :high_priority

  # Another job is running a sync for the same syncable. The sync is still
  # pending, so retrying runs it after the other one finishes and never drops
  # the request. Bounded in practice: once the sync is no longer pending
  # (completed elsewhere, cancelled or marked stale after 24h) perform no-ops.
  retry_on Sync::ConcurrentSyncError, wait: 30.seconds, attempts: :unlimited

  # Accept a runtime-only flag to influence sync behavior without persisting config
  def perform(sync, balances_only: false)
    # Attach a transient predicate for this execution only
    begin
      sync.define_singleton_method(:balances_only?) { balances_only }
    rescue => e
      Rails.logger.warn("SyncJob: failed to attach balances_only? flag: #{e.class} - #{e.message}")
    end

    sync.perform
  end
end
