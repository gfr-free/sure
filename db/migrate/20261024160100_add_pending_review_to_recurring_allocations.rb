# A payment Sure posted by itself overnight still counts as paid, but waits
# for the user to confirm it or discard it (when the payment was not needed
# this time). Defaults to false, so existing payments need no review.
class AddPendingReviewToRecurringAllocations < ActiveRecord::Migration[8.1]
  def change
    add_column :recurring_allocations, :pending_review, :boolean, default: false, null: false
  end
end
