# The sidebar sparkline of a group or subgroup that is not a single account
# type (see AccountGroupSparklinesController), summed over the given accounts
# in the family currency. Type groups use AccountableSparkline.
class AccountGroupSparkline
  IDENTITY_COLUMNS = [ :id, :accountable_type, :plaid_account_id, :simplefin_account_id, Arel.sql("account_providers.id") ].freeze

  # Only these types can hold imported history that needs trimming.
  LINKED_HISTORY_TYPES = %w[Investment Crypto].freeze

  # Identity rows of every account a group sparkline may sum, keyed by account
  # id, so the sidebar can version all its group frames from one query.
  def self.identity_rows_by_account_id
    AccountableSparkline.scope
      .left_outer_joins(:account_providers)
      .pluck(*IDENTITY_COLUMNS)
      .group_by(&:first)
  end

  def initialize(account_ids:, favorable_direction:, account_identity_rows: nil)
    @account_ids = account_ids
    @favorable_direction = favorable_direction
    @account_identity_rows = account_identity_rows
  end

  def empty?
    account_identity_rows.empty?
  end

  def series
    Rails.cache.fetch(cache_key, expires_in: 24.hours) { build_series }
  end

  # Changes whenever the sparkline or the requesting frame does; the sidebar
  # puts it in the frame URL. The response is addressed to its frame, and the
  # browser caches by URL, so every frame needs a URL of its own.
  def version(frame_id)
    Digest::SHA256.hexdigest("#{cache_key}_#{frame_id}_#{I18n.locale}").first(16)
  end

  # The series is built from exactly these account rows, so the key carries a
  # digest of them; it changes whenever the counted set does.
  def cache_key
    @cache_key ||= family.build_cache_key(
      "account_group_sparkline_#{Account::Chartable::SPARKLINE_CACHE_VERSION}_#{@favorable_direction}_#{Date.current}_#{account_rows_digest}",
      invalidate_on_data_updates: true
    )
  end

  private
    def family
      @family ||= Current.family
    end

    # The given accounts, narrowed by the same rules as the type sparkline.
    def account_identity_rows
      @account_identity_rows ||= AccountableSparkline.scope
        .where(id: @account_ids)
        .left_outer_joins(:account_providers)
        .pluck(*IDENTITY_COLUMNS)
    end

    def counted_account_ids
      account_identity_rows.map(&:first).uniq
    end

    def build_series
      options = {
        account_ids: counted_account_ids,
        currency: family.currency,
        period: Period.last_30_days,
        favorable_direction: @favorable_direction,
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
      account_identity_rows.any? do |_id, accountable_type, plaid_account_id, simplefin_account_id, account_provider_id|
        LINKED_HISTORY_TYPES.include?(accountable_type) &&
          (plaid_account_id.present? || simplefin_account_id.present? || account_provider_id.present?)
      end
    end

    def account_rows_digest
      Digest::SHA256.hexdigest(account_identity_rows.map { |row| row.join(":") }.sort.join(","))
    end
end
