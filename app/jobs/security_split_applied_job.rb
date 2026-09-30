# Recalculates holdings after a stock split was added, changed or removed.
#
# Split-adjusted price history (Yahoo, Twelve Data) that was stored before the
# provider knew of the split is still on the old basis, so it is fetched again
# up to the split date. Then every account holding the security (or, for a
# family's own split, every account of that family) syncs in full, because the
# split changes all history before its date.
#
# An account that is syncing right now may already have calculated with the
# old prices, and a sync requested meanwhile would merge into that running one
# and be lost, so such accounts are retried once it has finished.
class SecuritySplitAppliedJob < ApplicationJob
  queue_as :medium_priority

  RETRY_DELAY = 1.minute
  MAX_ATTEMPTS = 30

  def perform(security_id:, family_id:, split_date:, account_ids: nil, attempts_remaining: MAX_ATTEMPTS)
    security = Security.find_by(id: security_id)
    return unless security

    refetch_adjusted_prices(security, Date.iso8601(split_date)) if account_ids.nil?

    accounts = account_ids ? Account.where(id: account_ids) : Security::Split.affected_accounts(security: security, family_id: family_id)
    busy_account_ids = []

    accounts.find_each do |account|
      if account.syncs.visible.syncing.exists?
        busy_account_ids << account.id
      else
        account.sync_later
      end
    end

    retry_busy_accounts(busy_account_ids, security, family_id, split_date, attempts_remaining)
  end

  private
    def refetch_adjusted_prices(security, split_date)
      return if security.offline?
      return unless security.price_data_provider&.split_adjusted_prices?

      first_price_date = security.prices.minimum(:date)
      return if first_price_date.nil? || first_price_date >= split_date

      security.import_provider_prices(start_date: first_price_date, end_date: split_date - 1.day, clear_cache: true)
    end

    def retry_busy_accounts(account_ids, security, family_id, split_date, attempts_remaining)
      return if account_ids.empty?

      if attempts_remaining.positive?
        self.class.set(wait: RETRY_DELAY).perform_later(
          security_id: security.id,
          family_id: family_id,
          split_date: split_date,
          account_ids: account_ids,
          attempts_remaining: attempts_remaining - 1
        )
      else
        DebugLogEntry.capture(
          category: "background_jobs",
          level: "warn",
          message: "Gave up waiting to recalculate accounts after a stock split",
          source: self.class.name,
          metadata: { security_id: security.id, ticker: security.ticker, account_ids: account_ids, split_date: split_date }
        )
      end
    end
end
