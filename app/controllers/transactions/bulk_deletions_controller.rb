class Transactions::BulkDeletionsController < ApplicationController
  def create
    # Exclude split children from bulk delete - they must be deleted via unsplit on parent
    # Only allow deletion from accounts where user has owner or full_control permission
    writable_account_ids = writable_accounts.pluck(:id)
    entry_ids = bulk_delete_params[:entry_ids]

    # A selected transfer leg deletes the whole transfer (both legs and fees),
    # which needs write access to every account involved; otherwise it is kept.
    transfers = Transfer.with_legs_in(Current.accessible_entries.where(id: entry_ids)).to_a
    deletable, kept = transfers.partition { |transfer| transfer.deletable_with?(writable_account_ids.to_set) }
    transfer_entry_ids = transfers.flat_map { |transfer| [ transfer.inflow_transaction.entry&.id, transfer.outflow_transaction.entry&.id ] }.compact

    entries_scope = Current.family.entries
                      .where(account_id: writable_account_ids)
                      .where(parent_entry_id: nil)
                      .where.not(id: transfer_entry_ids)

    destroyed = Entry.transaction do
      entries_scope.destroy_by(id: entry_ids) + deletable.flat_map(&:destroy_with_transactions!)
    end
    destroyed.map(&:account).uniq.each(&:sync_later)

    flash_options = { notice: "#{destroyed.count} transaction#{destroyed.count == 1 ? "" : "s"} deleted" }
    flash_options[:alert] = t(".transfers_kept", count: kept.size) if kept.any?

    redirect_back_or_to transactions_url, **flash_options
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end

    def writable_accounts
      Current.family.accounts.writable_by(Current.user)
    end
end
