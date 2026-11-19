class DataCacheClearJob < ApplicationJob
  queue_as :low_priority

  SYNC_RETRY_WAIT = 1.minute

  # Market data is refreshed before anything is deleted: the holdings decide
  # which security prices are needed, and the account syncs must start with
  # the refreshed exchange rates.
  #
  # A sync that is already running would have its freshly written balances
  # deleted, and sync_later would only join it, so the job waits for it.
  def perform(family)
    return retry_later(family) if sync_running?(family)

    Family::MarketDataRefresher.new(family).refresh

    # The family and account locks keep sync_later from starting a sync
    # between the check and the delete
    family.with_lock do
      family.accounts.order(:id).lock.pluck(:id)

      if sync_running?(family)
        retry_later(family)
      else
        Balance.where(account_id: family.accounts.select(:id)).delete_all
        holdings = Holding.where(account_id: family.accounts.select(:id))
        holdings.where.not(id: corrected_holding_ids(holdings)).delete_all

        family.sync_later
      end
    end
  end

  private
    # A cost basis the user entered or a security they remapped lives only on
    # holding rows, so the rows that carry one stay; the sync rewrites their
    # values. Only a position's latest row counts, as it does when a provider
    # import carries a correction forward: one the user has since undone on
    # the latest row is not revived from an older one.
    #
    # A provider's row stays only on that provider's latest snapshot, and then
    # with the rest of that snapshot: the latest snapshot stands for the whole
    # position list until the next import, so part of it would hide every
    # other security.
    def corrected_holding_ids(holdings)
      corrected = Holding
        .from(holdings.select("DISTINCT ON (holdings.account_id, holdings.account_provider_id, holdings.security_id) holdings.*")
          .order("holdings.account_id, holdings.account_provider_id, holdings.security_id, holdings.date DESC, holdings.id"), :holdings)
        .where("holdings.cost_basis_locked OR holdings.security_locked")
        .pluck(:id, :account_provider_id, :date)
      provider_rows, own_rows = corrected.partition { |_, account_provider_id, _| account_provider_id }
      return own_rows.map(&:first) if provider_rows.empty?

      provider_holdings = holdings.where(account_provider_id: provider_rows.map { |_, account_provider_id, _| account_provider_id })
      latest_dates = provider_holdings.group(:account_provider_id).maximum(:date)
      snapshots = provider_rows
        .map { |_, account_provider_id, date| [ account_provider_id, date ] }.uniq
        .select { |account_provider_id, date| latest_dates[account_provider_id] == date }
        .map { |account_provider_id, date| provider_holdings.where(account_provider_id: account_provider_id, date: date) }
      snapshot_ids = snapshots.reduce(:or)&.ids || []

      own_rows.map(&:first) + snapshot_ids
    end

    def sync_running?(family)
      Sync.visible.where(syncable: family)
        .or(Sync.visible.where(syncable_type: "Account", syncable_id: family.accounts.select(:id)))
        .exists?
    end

    def retry_later(family)
      self.class.set(wait: SYNC_RETRY_WAIT).perform_later(family)
    end
end
