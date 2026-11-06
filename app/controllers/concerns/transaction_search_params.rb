# Reads the permitted transaction search filters from the q param. Shared by
# the transactions index and the lazily loaded filter menu so both see the
# same cleaned filter set.
module TransactionSearchParams
  extend ActiveSupport::Concern

  private
    # Permitted search filters from the q param, with blank values and
    # unsupported ai_status / attachment_status values dropped.
    def search_params
      cleaned_params = params.fetch(:q, {})
              .permit(
                :start_date, :end_date, :search, :amount,
                :amount_operator, :active_accounts_only,
                accounts: [], account_ids: [],
                categories: [], merchants: [], types: [], tags: [], status: [], ai_status: [],
                attachment_status: []
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

      cleaned_params
    end
end
