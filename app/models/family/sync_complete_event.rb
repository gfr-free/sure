class Family::SyncCompleteEvent
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def broadcast
    # Replace the #sync-toast slot with a lightweight toast instead of a full
    # page refresh.  The sync-toast Stimulus controller handles three cases:
    #   - User is idle         → morph-refreshes after a short delay
    #   - User is mid-form     → toast stays visible; user clicks "Refresh"
    #   - A modal is open      → toast defers until the dialog closes
    #
    # This avoids wiping in-progress form state when a background sync fires.
    # The partial contains no user-scoped data (Current.user is nil here), so
    # each browser re-fetches the page on its own authenticated request.
    #
    # Syncing several connections (or "Sync all") finishes one sync after
    # another, and every one of them lands here. Only the last one to finish
    # sends the toast, so the page refreshes once instead of once per sync;
    # account rows are already replaced in place as each sync completes.
    broadcast_toast_if_idle

    # The accounts page's own sync toolbar (refresh icon + "Cancel sync") is
    # plain server-rendered HTML from whatever request last loaded the page,
    # so without this it stays stuck showing "still syncing" — disabled icon,
    # "Cancel sync" visible — indefinitely after the sync actually finishes,
    # even while the toast above says otherwise. Replace it in the same
    # broadcast so the two agree. Visitors not on the accounts page simply
    # don't have #accounts-sync-controls in their DOM, so this no-ops for
    # them, same as the sync-toast replace above.
    family.broadcast_replace_to(
      family,
      target: "accounts-sync-controls",
      partial: "accounts/sync_controls",
      locals: { family: family }
    )

    # Schedule recurring transaction pattern identification (debounced to run after all syncs complete)
    begin
      RecurringTransaction.identify_patterns_for(family)
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent recurring transaction identification failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end
  end

  # Sends the toast unless another sync of the family is still running; that
  # sync sends it when it finishes (or ends stale, see Sync#mark_stale).
  # The check runs after commit: this is called inside the finalizing sync's
  # locked transaction, and two syncs finishing concurrently would otherwise
  # each see the other's uncommitted "syncing" row and both stay silent.
  def broadcast_toast_if_idle
    ActiveRecord.after_all_transactions_commit do
      broadcast_sync_toast unless other_syncs_in_progress?
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent sync toast broadcast failed: #{e.message}")
    end
  end

  private
    def broadcast_sync_toast
      family.broadcast_replace_to(
        family,
        target: "sync-toast",
        partial: "shared/notifications/sync_toast"
      )
    end

    # Sync.visible ignores syncs started more than Sync::VISIBLE_FOR ago, so a
    # hung sync only holds back the toast for syncs finishing within that window.
    def other_syncs_in_progress?
      Sync.for_family(family).visible.exists?
    end
end
