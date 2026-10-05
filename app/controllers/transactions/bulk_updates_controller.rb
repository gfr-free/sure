class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    # Skip split parents from bulk update - update children instead
    entries = Current.family
                     .entries
                     .excluding_split_parents
                     .where(id: bulk_update_params[:entry_ids])
    updated = entries.includes(:entryable).bulk_update!(bulk_update_params, update_tags: tags_provided?)

    Rule.apply_immediately_later(Current.family, entries.where(entryable_type: "Transaction").pluck(:entryable_id)) if updated.positive?

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't touch tags field".
    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
