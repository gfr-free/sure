class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    # Skip split parents from bulk update - update children instead
    updated = Current.family
                     .entries
                     .excluding_split_parents
                     .where(id: bulk_update_params[:entry_ids])
                     .includes(:entryable)
                     .bulk_update!(scoped_bulk_update_params, update_tags: tags_provided?)

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end

    # The ids arrive straight from the form, so resolve them through the family:
    # an unknown category or merchant is a 404 and foreign tag ids are dropped,
    # matching the single-transaction edit paths.
    def scoped_bulk_update_params
      attrs = bulk_update_params.to_h.with_indifferent_access

      if attrs[:category_id].present?
        attrs[:category_id] = Current.family.categories.find(attrs[:category_id]).id
      end

      if attrs[:merchant_id].present?
        attrs[:merchant_id] = Current.family.available_merchants_for(Current.user).find(attrs[:merchant_id]).id
      end

      if attrs.key?(:tag_ids)
        attrs[:tag_ids] = Current.family.tags.where(id: Array(attrs[:tag_ids]).compact_blank).pluck(:id)
      end

      attrs
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't touch tags field".
    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
