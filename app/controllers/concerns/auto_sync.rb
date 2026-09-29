module AutoSync
  extend ActiveSupport::Concern

  included do
    before_action :sync_family, if: :family_needs_auto_sync?
  end

  private
    def sync_family
      # Atomic claim so concurrent first requests of the day (page + frames,
      # parallel tabs) enqueue the family sync and Plaid refresh only once.
      return unless claim_auto_sync_slot

      begin
        Current.family.request_plaid_transactions_refreshes_later(source: "AutoSync")
        Current.family.sync_later
      rescue
        Rails.cache.delete(auto_sync_cache_key)
        raise
      end
    end

    def family_needs_auto_sync?
      return false unless auto_sync_navigation_request?
      return false unless Current.family&.accounts&.active&.any?
      return false if (Current.family.last_sync_created_at&.to_date || 1.day.ago) >= Date.current
      return false unless Current.family.auto_sync_on_login

      Rails.logger.info "Auto-syncing family #{Current.family.id}, last sync was #{Current.family.last_sync_created_at}"

      true
    end

    # Only top-level HTML navigations trigger auto-sync; turbo-frame loads,
    # XHR/JSON/turbo-stream requests and Turbo link prefetches do not.
    def auto_sync_navigation_request?
      request.format.html? && !turbo_frame_request? && !request.xhr? && !auto_sync_prefetch_request?
    end

    def auto_sync_prefetch_request?
      %w[Sec-Purpose X-Sec-Purpose Purpose].any? { |header| request.headers[header].to_s.include?("prefetch") }
    end

    def claim_auto_sync_slot
      Rails.cache.write(auto_sync_cache_key, true, unless_exist: true, expires_in: 1.day)
    end

    def auto_sync_cache_key
      "auto_sync:#{Current.family.id}:#{Date.current.iso8601}"
    end
end
