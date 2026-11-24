# The transactions search filters (q param), shared by every page that runs a
# Transaction::Search with the full filter menu.
module TransactionSearchParams
  extend ActiveSupport::Concern

  private
    # Permitted search filters from the q param, with blank values and
    # unsupported ai_status / attachment_status / review_state values dropped.
    def search_params
      cleaned_params = params.fetch(:q, {})
              .permit(
                :start_date, :end_date, :search, :amount,
                :amount_operator, :active_accounts_only,
                accounts: [], account_ids: [],
                categories: [], merchants: [], types: [], tags: [], status: [], ai_status: [],
                attachment_status: [], reconcile_status: [], review_state: []
              )
              .to_h
              .compact_blank

      cleaned_params.delete(:amount_operator) unless cleaned_params[:amount].present?

      if cleaned_params[:ai_status]
        cleaned_params[:ai_status] &= Transaction::Search::AI_STATUSES
        cleaned_params.delete(:ai_status) if cleaned_params[:ai_status].empty?
      end

      if cleaned_params[:attachment_status]
        cleaned_params[:attachment_status] &= Transaction::Search::ATTACHMENT_STATUSES
        cleaned_params.delete(:attachment_status) if cleaned_params[:attachment_status].empty?
      end

      if cleaned_params[:review_state]
        cleaned_params[:review_state] &= Transaction::REVIEW_STATE_FILTER_VALUES
        cleaned_params.delete(:review_state) if cleaned_params[:review_state].empty?
      end

      cleaned_params
    end
end
