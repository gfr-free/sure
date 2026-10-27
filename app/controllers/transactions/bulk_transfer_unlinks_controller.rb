class Transactions::BulkTransferUnlinksController < ApplicationController
  def create
    writable_account_ids = Current.family.accounts.writable_by(Current.user).pluck(:id).to_set
    transfers = selected_transfers.select { |transfer| transfer.unlinkable_with?(writable_account_ids) }
    accounts = transfers.flat_map { |transfer| [ transfer.from_account, transfer.to_account ] }.compact.uniq

    # Rejecting (not just destroying) keeps the next account sync from
    # auto-matching the same pair again as a pending transfer.
    Transfer.transaction { transfers.each(&:reject!) }
    accounts.each(&:sync_later)

    skipped = selected_transfers.size - transfers.size
    flash_options = { notice: t(".success", count: transfers.size) }
    flash_options[:alert] = t(".skipped", count: skipped) if skipped.positive?

    redirect_back_or_to transactions_url, **flash_options
  end

  private
    def bulk_transfer_unlink_params
      params.require(:bulk_transfer_unlink).permit(entry_ids: [])
    end

    # Transfers with at least one selected leg in an account the user can see.
    def selected_transfers
      @selected_transfers ||= begin
        transaction_ids = Current.accessible_entries
                                 .where(id: bulk_transfer_unlink_params[:entry_ids], entryable_type: "Transaction")
                                 .select(:entryable_id)

        Transfer.where(inflow_transaction_id: transaction_ids)
                .or(Transfer.where(outflow_transaction_id: transaction_ids))
                .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account }, fee_transactions: :entry)
                .to_a
      end
    end
end
