class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    # Skip split parents from bulk update - update children instead
    scoped_params = family_scoped_bulk_update_params

    updated = Current.family
                     .entries
                     .joins(:account)
                     .merge(Account.annotatable_by(Current.user))
                     .excluding_split_parents
                     .where(id: bulk_update_params[:entry_ids])
                     .includes(:entryable)
                     .bulk_update!(scoped_params, update_tags: scoped_params.key?(:tag_ids))

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
        resolved = tag_ids.any? ? Current.family.tags.where(id: tag_ids).pluck(:id) : []

        # Tags were requested but none belong to this family: leave the entries'
        # tags alone instead of wiping them. An explicit empty list still clears.
        if tag_ids.any? && resolved.empty?
          scoped.delete(:tag_ids)
        else
          scoped[:tag_ids] = resolved
        end
      end

      scoped
    end
end
