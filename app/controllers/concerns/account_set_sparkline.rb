# Sidebar sparkline summed over a set of accounts in the family currency,
# shared by the account type groups (AccountableSparklinesController) and all
# other groups and subgroups (AccountGroupSparklinesController). Including
# controllers define #account_scope, #sparkline_favorable_direction and
# #sparkline_cache_name.
module AccountSetSparkline
  extend ActiveSupport::Concern

  # Only these types can hold imported history that needs trimming.
  LINKED_HISTORY_TYPES = %w[Investment Crypto].freeze

  private
    def render_account_set_sparkline
      etag_key = sparkline_cache_key

      # Use HTTP conditional GET so the client receives 304 Not Modified when possible.
      if stale?(etag: etag_key, last_modified: Current.family.latest_sync_completed_at)
        @series = Rails.cache.fetch(etag_key, expires_in: 24.hours) do
          build_sparkline_series
        end

        render layout: false
      end
    end

    def sparkline_account_rows
      @sparkline_account_rows ||= account_scope
        .left_outer_joins(:account_providers)
        .pluck(:id, :accountable_type, :plaid_account_id, :simplefin_account_id, Arel.sql("account_providers.id"))
    end

    def sparkline_account_ids
      @sparkline_account_ids ||= sparkline_account_rows.map(&:first).uniq
    end

    def build_sparkline_series
      options = {
        account_ids: sparkline_account_ids,
        currency: Current.family.currency,
        period: Period.last_30_days,
        favorable_direction: sparkline_favorable_direction,
        interval: "1 day"
      }

      if requires_normalized_aggregation?
        Balance::LinkedInvestmentSeriesNormalizer.aggregate_account_ids(**options)
      else
        Balance::ChartSeriesBuilder.new(**options).balance_series
      end
    end

    # Linked investment and crypto accounts need their imported history
    # trimmed. Decided from the plucked rows, the SQL-level mirror of
    # `Account#linked?`, so no account is loaded.
    def requires_normalized_aggregation?
      sparkline_account_rows.any? do |_id, accountable_type, plaid_account_id, simplefin_account_id, account_provider_id|
        LINKED_HISTORY_TYPES.include?(accountable_type) &&
          (plaid_account_id.present? || simplefin_account_id.present? || account_provider_id.present?)
      end
    end

    # The series is built from exactly these account rows, so the key carries a
    # digest of them. A share count/timestamp version can stay the same while
    # access changes (ownership moved by update_all, shares replaced with older
    # timestamps); the row digest changes whenever the accessible set does and
    # never repeats for a different set.
    def sparkline_cache_key
      Current.family.build_cache_key(
        "#{sparkline_cache_name}_#{Account::Chartable::SPARKLINE_CACHE_VERSION}_#{sparkline_rows_digest}",
        invalidate_on_data_updates: true
      )
    end

    def sparkline_rows_digest
      Digest::SHA256.hexdigest(sparkline_account_rows.map { |row| row.join(":") }.sort.join(","))
    end
end
