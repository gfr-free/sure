# The sidebar sparkline of a group or subgroup that is not a single account
# type (see AccountGroupSparklinesController), summed over the group's counted
# accounts in the family currency. Type groups use AccountableSparkline.
class AccountGroupSparkline
  IDENTITY_COLUMNS = [ :id, :accountable_type, :plaid_account_id, :simplefin_account_id, Arel.sql("account_providers.id") ].freeze

  # Only these types can hold imported history that needs trimming.
  LINKED_HISTORY_TYPES = %w[Investment Crypto].freeze

  class << self
    # The accounts the group total next to the sparkline counts.
    def counted_account_ids(group)
      BalanceSheet::ClassificationGroup.counted_accounts(group.accounts).map(&:id)
    end

    def favorable_direction_for(classification)
      classification == "liability" ? "down" : "up"
    end

    # Identity rows of every account a group sparkline may sum, keyed by
    # account id, so the sidebar can version all its group frames from one query.
    def identity_rows_by_account_id
      AccountableSparkline.scope
        .left_outer_joins(:account_providers)
        .pluck(*IDENTITY_COLUMNS)
        .group_by(&:first)
    end

    # The family part of the cache key, shared by all groups of one sidebar.
    def cache_key_prefix
      Current.family.build_cache_key(
        "account_group_sparkline_#{Account::Chartable::SPARKLINE_CACHE_VERSION}_#{Date.current}",
        invalidate_on_data_updates: true
      )
    end
  end

  def initialize(account_ids:, classification:, account_identity_rows: nil, cache_key_prefix: nil)
    @account_ids = account_ids
    @favorable_direction = self.class.favorable_direction_for(classification)
    @account_identity_rows = account_identity_rows
    @cache_key_prefix = cache_key_prefix
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
    @cache_key ||= "#{@cache_key_prefix || self.class.cache_key_prefix}_#{@favorable_direction}_#{account_rows_digest}"
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

    def series_options(account_ids)
      {
        account_ids: account_ids,
        currency: family.currency,
        period: Period.last_30_days,
        favorable_direction: @favorable_direction,
        interval: "1 day"
      }
    end

    def build_series
      series = Balance::ChartSeriesBuilder.new(**series_options(counted_account_ids)).balance_series
      return series if linked_history_account_ids.empty?

      trim_to_linked_history(series)
    end

    # Linked investment and crypto accounts only have reliable history from
    # their first imported activity on, so the line starts there, as for the
    # type sparkline. Only those accounts decide the start: other imported
    # accounts in a mixed group keep their full history.
    def trim_to_linked_history(series)
      linked = Balance::LinkedInvestmentSeriesNormalizer.aggregate_account_ids(**series_options(linked_history_account_ids))
      start_date = linked.values.first&.date
      return series unless start_date

      values = series.values.select { |value| value.date >= start_date }
      return series if values.blank? || values.length == series.values.length

      Series.new(
        start_date: values.first.date,
        end_date: series.end_date,
        interval: series.interval,
        values: values,
        favorable_direction: series.favorable_direction
      )
    end

    # Decided from the plucked rows, the SQL-level mirror of `Account#linked?`,
    # so no account is loaded.
    def linked_history_account_ids
      @linked_history_account_ids ||= account_identity_rows.filter_map do |id, accountable_type, plaid_account_id, simplefin_account_id, account_provider_id|
        id if LINKED_HISTORY_TYPES.include?(accountable_type) &&
          (plaid_account_id.present? || simplefin_account_id.present? || account_provider_id.present?)
      end.uniq
    end

    def account_rows_digest
      Digest::SHA256.hexdigest(account_identity_rows.map { |row| row.join(":") }.sort.join(","))
    end
end
