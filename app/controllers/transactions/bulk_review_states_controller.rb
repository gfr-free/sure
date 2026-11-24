# Sets the manual review mark on the transactions selected in a list. Rows
# the user may only read are skipped, as in the bulk edit. Preview-gated.
class Transactions::BulkReviewStatesController < ApplicationController
  before_action :require_preview_features!
  before_action :require_non_guest!

  def create
    state = Transaction.review_state_from_param(bulk_params[:state])
    if state == :invalid
      redirect_back_or_to transactions_path, alert: t("transactions.review_state.failure")
      return
    end

    # Split parents are hidden; their parts carry the mark.
    entries = Current.annotatable_entries
                     .excluding_split_parents
                     .where(entryable_type: "Transaction", id: Array.wrap(bulk_params[:entry_ids]))
    updated = Transaction.set_review_state!(Transaction.where(id: entries.select(:entryable_id)), state, user: Current.user)

    redirect_back_or_to transactions_path,
      notice: t("transactions.review_state.bulk_updated.#{state || Transaction::REVIEW_STATE_OPEN}", count: updated)
  end

  private
    def bulk_params
      params.require(:bulk_review_state).permit(:state, entry_ids: [])
    end
end
