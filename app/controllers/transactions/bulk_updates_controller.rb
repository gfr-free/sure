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
                     .bulk_update!(family_scoped_bulk_update_params, update_tags: tags_provided?)

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end

    # Resolve category, merchant and tag IDs through the current family so IDs
    # belonging to another family are dropped instead of being attached.
    def family_scoped_bulk_update_params
      scoped = bulk_update_params.to_h.symbolize_keys

      if scoped[:category_id].present?
        scoped[:category_id] = Current.family.categories.where(id: scoped[:category_id]).pick(:id)
      end

      if scoped[:merchant_id].present?
        scoped[:merchant_id] = Current.family.available_merchants_for(Current.user).where(id: scoped[:merchant_id]).pick(:id)
      end

      if scoped.key?(:tag_ids)
        tag_ids = Array.wrap(scoped[:tag_ids]).reject(&:blank?)
        scoped[:tag_ids] = tag_ids.any? ? Current.family.tags.where(id: tag_ids).pluck(:id) : []
      end

      scoped
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't touch tags field".
    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
