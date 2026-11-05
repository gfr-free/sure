class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    # Skip split parents from bulk update - update children instead
    scoped_params = family_scoped_bulk_update_params
    entry_ids = bulk_update_params[:entry_ids]

    # Transfer legs are edited as a transfer (see Transfer#apply_bulk_update!),
    # never as two independent transactions.
    transfers = Transfer.with_legs_in(Current.accessible_entries.where(id: entry_ids)).to_a
    transfer_entry_ids = transfers.flat_map { |transfer| [ transfer.inflow_transaction.entry&.id, transfer.outflow_transaction.entry&.id ] }.compact

    selected = Current.annotatable_entries
                      .excluding_split_parents
                      .where(id: entry_ids)
                      .where.not(id: transfer_entry_ids)

    # Owners and full_control shares may change every field; read_write shares
    # may only annotate (notes, category, merchant, tags), as on a single entry.
    # Read-only and unshared accounts are left out entirely.
    rows = selected.pluck(:id, Account.writable_by_sql(Current.user))
    full_ids = rows.select(&:last).map(&:first).uniq
    annotate_ids = rows.map(&:first).uniq - full_ids

    updated = Entry.transaction do
      bulk_update_entries(full_ids, scoped_params) +
        bulk_update_entries(annotate_ids, scoped_params.slice(*AccountShare::ANNOTATE_ENTRY_ATTRIBUTES, *AccountShare::ANNOTATE_TRANSACTION_ATTRIBUTES)) +
        bulk_update_transfers(transfers, scoped_params)
    end

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    # Same permissions as editing one transfer: category and notes need full
    # access to both endpoints, tags need annotate access to both.
    def bulk_update_transfers(transfers, attributes)
      return 0 if transfers.empty?

      writable_ids = Current.family.accounts.writable_by(Current.user).pluck(:id).to_set
      annotatable_ids = Current.family.accounts.annotatable_by(Current.user).pluck(:id).to_set
      update_tags = attributes.key?(:tag_ids)

      transfers.count do |transfer|
        endpoint_ids = [ transfer.from_account&.id, transfer.to_account&.id ]
        next false if endpoint_ids.any?(&:nil?)

        full_access = endpoint_ids.all? { |id| writable_ids.include?(id) }
        tag_access = update_tags && endpoint_ids.all? { |id| annotatable_ids.include?(id) }
        next false unless full_access || tag_access

        transfer.apply_bulk_update!(attributes, full_access: full_access, update_tags: tag_access)
      end
    end

    def bulk_update_entries(entry_ids, attributes)
      return 0 if entry_ids.empty?

      Current.family.entries.where(id: entry_ids).includes(:entryable)
             .bulk_update!(attributes, update_tags: attributes.key?(:tag_ids))
    end

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
