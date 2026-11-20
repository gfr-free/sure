class Transactions::BulkUpdatesController < ApplicationController
  def new
    # The selection bar sends these flags so the drawer can hide fields that
    # do not apply to the selected entries. They control display only; the
    # server still enforces the same rules in Entry.bulk_update!.
    @has_transaction_entry = params[:has_transaction_entry] != "false"
    @has_transfer_entry = params[:has_transfer_entry] == "true"
    @has_category_editable_entry = params[:has_category_editable_entry] != "false"
    @has_normal_transaction_entry = params[:has_normal_transaction_entry] != "false"
  end

  def create
    # Reject an out-of-range reconciled_status before it ever reaches
    # bulk_update! — the enum's `validate: true` means an invalid value
    # would otherwise raise ActiveRecord::RecordInvalid partway through the
    # bulk transaction. The single-row TransactionsController#reconcile
    # action can't hit this (advance_reconciled_status! only ever assigns a
    # value from RECONCILED_STATUS_CYCLE), but this form field takes
    # arbitrary user input, so it needs the same graceful-failure handling.
    reconciled_status = bulk_update_params[:reconciled_status]
    if reconciled_status.present? && !Current.family.manual_reconciliation?
      redirect_back_or_to transactions_path, alert: t("transactions.reconcile.unavailable")
      return
    end

    if reconciled_status.present? && !Entry.reconciled_statuses.key?(reconciled_status)
      redirect_back_or_to transactions_path, alert: t("transactions.reconcile.failure")
      return
    end

    # Skip split parents from bulk update - update children instead
    scoped_params = family_scoped_bulk_update_params
    entry_ids = bulk_update_params[:entry_ids]

    # Transfer legs are edited as a transfer (see Transfer#apply_bulk_update!),
    # never as two independent transactions.
    transfers = Transfer.with_legs_in(Current.accessible_entries.where(id: entry_ids)).to_a
    transfer_entry_ids = transfers.flat_map { |transfer| transfer_leg_entry_ids(transfer) }

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

    changed_ids = []
    collect_changed = ->(entry) { changed_ids << entry.entryable_id }

    updated = Entry.transaction do
      # The groups below lock their rows in different orders. Lock the full
      # selection first, so requests with opposite permissions cannot deadlock.
      Entry.lock_for_bulk_update!(full_ids + annotate_ids + transfer_entry_ids)

      bulk_update_entries(full_ids, scoped_params, &collect_changed) +
        bulk_update_entries(annotate_ids, scoped_params.slice(*AccountShare::ANNOTATE_ENTRY_ATTRIBUTES, *AccountShare::ANNOTATE_TRANSACTION_ATTRIBUTES), &collect_changed) +
        bulk_update_transfer_legs(transfers, Array.wrap(entry_ids), scoped_params)
    end

    Rule.apply_immediately_later(Current.family, changed_ids)

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  rescue ActiveRecord::RecordInvalid => e
    DebugLogEntry.capture(
      category: "reconciliation",
      level: "error",
      message: "Bulk transaction update failed: #{e.message}",
      source: "Transactions::BulkUpdatesController#create",
      family: Current.family,
      user: Current.user,
      metadata: {
        error_class: e.class.name,
        error_message: e.message,
        entry_ids: bulk_update_params[:entry_ids]
      }
    )
    # Base errors (e.g. a refused sale) are written for the user; anything else stays generic.
    alert = e.record.errors[:base].to_sentence.presence || t("transactions.reconcile.failure")
    redirect_back_or_to transactions_path, alert: alert
  end

  private
    # Counts each selected transfer leg once, whether its transfer was edited,
    # the leg was reconciled, or both.
    def bulk_update_transfer_legs(transfers, entry_ids, attributes)
      return 0 if transfers.empty?

      selected_leg_ids = transfers.flat_map { |transfer| transfer_leg_entry_ids(transfer) } & entry_ids
      changed_leg_ids = bulk_update_transfers(transfers, attributes)
                          .flat_map { |transfer| transfer_leg_entry_ids(transfer) } & entry_ids
      reconciled_leg_ids = bulk_reconcile_transfer_legs(selected_leg_ids, attributes)

      (changed_leg_ids | reconciled_leg_ids).size
    end

    # Same permissions as editing one transfer: category and notes need full
    # access to both endpoints, tags need annotate access to both. Returns the
    # transfers that changed.
    def bulk_update_transfers(transfers, attributes)
      writable_ids = Current.family.accounts.writable_by(Current.user).pluck(:id).to_set
      annotatable_ids = Current.family.accounts.annotatable_by(Current.user).pluck(:id).to_set
      update_tags = attributes.key?(:tag_ids)

      transfers.select do |transfer|
        endpoint_ids = [ transfer.from_account&.id, transfer.to_account&.id ]
        next false if endpoint_ids.any?(&:nil?)

        full_access = endpoint_ids.all? { |id| writable_ids.include?(id) }
        tag_access = update_tags && endpoint_ids.all? { |id| annotatable_ids.include?(id) }
        next false unless full_access || tag_access

        transfer.apply_bulk_update!(attributes, full_access: full_access, update_tags: tag_access)
      end
    end

    # Manual reconciliation stays per leg, like on a single transaction: only
    # the selected leg changes, it needs write access to its own account, and
    # only legs on manual accounts take a status. Returns the reconciled ids.
    def bulk_reconcile_transfer_legs(entry_ids, attributes)
      return [] if entry_ids.empty? || attributes[:reconciled_status].blank?

      rows = Current.annotatable_entries.where(id: entry_ids).pluck(:id, Account.writable_by_sql(Current.user))
      writable_ids = rows.select(&:last).map(&:first).uniq
      reconcilable_ids = Current.family.entries.where(id: writable_ids).includes(:account)
                                .select { |entry| entry.account.manual? }.map(&:id)
      bulk_update_entries(reconcilable_ids, attributes.slice(:reconciled_status))
      reconcilable_ids
    end

    def transfer_leg_entry_ids(transfer)
      [ transfer.inflow_transaction.entry&.id, transfer.outflow_transaction.entry&.id ].compact
    end

    def bulk_update_entries(entry_ids, attributes, &on_change)
      return 0 if entry_ids.empty?

      Current.family.entries.where(id: entry_ids).includes(:entryable)
             .bulk_update!(attributes, update_tags: attributes.key?(:tag_ids), &on_change)
    end

    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, :reconciled_status, entry_ids: [], tag_ids: [])
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
