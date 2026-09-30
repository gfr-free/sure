# Shows an unread dot on synced/imported transactions a user has not seen yet
# and marks them read as soon as a list page renders them. The dot stays on the
# rows of this render; the next render of the same rows has none.
module UnreadEntriesTrackable
  extend ActiveSupport::Concern

  private
    # Sets @unread_entry_ids, which EntriesHelper#unread_entry? reads while the
    # rows render.
    def track_unread_entries(entries)
      entry_ids = entries.map(&:id)
      @unread_entry_ids = entry_ids.any? ? Current.user.unread_entries.where(id: entry_ids).pluck(:id).to_set : Set.new

      # Turbo hover-prefetches links; the user has not seen that response yet.
      Current.user.mark_entries_read!(@unread_entry_ids) unless prefetch_request?
    end

    # Turbo sends X-Sec-Purpose (the fetch spec forbids setting Sec-Purpose
    # from JS) on hover-prefetch requests.
    def prefetch_request?
      request.headers["X-Sec-Purpose"] == "prefetch" || request.headers["Sec-Purpose"].to_s.include?("prefetch")
    end
end
