# Sets the manual review mark (flagged / reviewed / open) on one transaction,
# from its drawer. Who may change it follows the account shares: owners,
# full_control and read_write, like category and merchant. Preview-gated.
class Transactions::ReviewStatesController < ApplicationController
  include StreamExtensions, ActionView::RecordIdentifier

  before_action :require_preview_features!
  before_action :require_non_guest!
  before_action :set_entry

  def update
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    if @entry.split_parent?
      respond_with_alert(t("transactions.review_state.split_parent"))
      return
    end

    state = Transaction.review_state_from_param(params[:state])
    if state == :invalid
      respond_with_alert(t("transactions.review_state.failure"))
      return
    end

    Transaction.set_review_state!(Transaction.where(id: @entry.entryable_id), state, user: Current.user)
    @entry.reload
    flash[:notice] = t("transactions.review_state.updated.#{state || Transaction::REVIEW_STATE_OPEN}")

    respond_to do |format|
      format.html { redirect_back_or_to transactions_path }
      format.turbo_stream do
        # The row reads these, as the list does.
        @accessible_account_ids = Current.user.accessible_accounts.pluck(:id)
        @transfer_hint_transaction_ids = Current.family.transaction_ids_with_transfer_candidates([ @entry.transaction ], user: Current.user)
        render turbo_stream: [
          turbo_stream.replace(
            dom_id(@entry, :review_state),
            partial: "transactions/review_state",
            locals: { entry: @entry, can_change: true }
          ),
          turbo_stream.replace(
            dom_id(@entry),
            partial: "entries/entry",
            locals: { entry: @entry, in_split_group: helpers.in_split_group?(@entry, params[:grouped]) }
          ),
          *flash_notification_stream_items
        ]
      end
    end
  end

  private
    def set_entry
      @entry = Current.family.entries
                 .where(entryable_type: "Transaction")
                 .joins(:account)
                 .merge(Account.accessible_by(Current.user))
                 .find(params[:transaction_id])
    end

    def respond_with_alert(message)
      respond_to do |format|
        format.html { redirect_back_or_to transaction_path(@entry), alert: message }
        format.turbo_stream { stream_redirect_back_or_to(transaction_path(@entry), alert: message) }
      end
    end
end
