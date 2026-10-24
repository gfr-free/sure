# Instance-wide counterpart to DataCacheClearJob, reserved for super admins.
#
# Exchange rates and security prices are shared by every family, so after
# deleting them we re-import everything the instance needs before any family
# syncs. Otherwise parallel account syncs race to re-import the same pairs and
# other families see unconverted (1:1) totals until the next scheduled import.
class MarketDataResetJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    ActiveRecord::Base.transaction do
      ExchangeRate.delete_all
      # Offline securities are never re-fetched, so their prices would be lost for good.
      Security::Price.where(security_id: Security.online.select(:id)).delete_all
    end

    importer = MarketDataImporter.new(mode: :full)
    # Import each kind on its own so a failure in one still leaves the other in
    # place before the family syncs start.
    import_step(:security_prices) { importer.import_security_prices }
    import_step(:exchange_rates) { importer.import_exchange_rates }

    Family.find_each do |family|
      family.sync_later
    rescue => e
      Rails.logger.error("MarketDataResetJob failed to sync family #{family.id}: #{e.message}")
    end
  end

  private
    # A failed import must not stop the family syncs: they fetch any rates and
    # prices that are still missing. Re-raising would retry the whole job and
    # delete the data again.
    def import_step(step)
      yield
    rescue => e
      Rails.logger.error("MarketDataResetJob #{step} import failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      DebugLogEntry.capture(
        category: "market_data",
        level: "error",
        message: "Market data re-import after reset failed; continuing with family syncs",
        source: self.class.name,
        metadata: { step: step, error_class: e.class.name }
      )
    end
end
