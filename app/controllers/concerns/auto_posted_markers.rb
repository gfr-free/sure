# Transaction lists mark the entries Sure posted for a recurring bill, with
# confirm and discard for the provisional ones.
module AutoPostedMarkers
  extend ActiveSupport::Concern

  private
    def load_auto_posted_markers(entry_ids)
      # Bills are a preview feature, and so is the marker for what they posted.
      return unless preview_features_enabled?

      @auto_posted_allocations = RecurringAllocation.auto_posted_by_entry(entry_ids)
      # The review buttons only for accounts this user may change.
      return unless @auto_posted_allocations.values.any?(&:pending_review?)

      @auto_post_writable_account_ids = Account.writable_by(Current.user).pluck(:id).to_set
    end
end
