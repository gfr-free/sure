class BalanceSheet::NetWorthBreakdownSeriesBuilder
  # Monthly interval regardless of period length so the reports chart always
  # shows one point per month in the selected range.
  INTERVAL = "1 month"
  CACHE_VERSION = "v3"

  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  # Returns a chart payload where each monthly point carries the net worth
  # value plus a per-account-group breakdown split into assets and
  # liabilities, for rendering in chart tooltips. Groups are formed by account
  # type unless another dimension is given (see AccountGrouping).
  def breakdown_series(period:, group_by: AccountGrouping::DEFAULT_PRIMARY)
    group_by = AccountGrouping::DEFAULT_PRIMARY unless AccountGrouping.valid_dimension?(group_by)

    Rails.cache.fetch(cache_key(period, group_by)) do
      net_series = series_for(historical_accounts, favorable_direction: "up", period: period)
      groups = group_series(period, group_by)

      {
        start_date: period.start_date,
        end_date: period.end_date,
        interval: INTERVAL,
        trend: net_series.trend,
        values: [ nil, *net_series.values ].each_cons(2).map do |previous, value|
          breakdown_value(value, previous, groups)
        end
      }
    end
  end

  private
    attr_reader :family, :user

    def breakdown_value(value, previous, groups)
      point_groups = groups.map do |group|
        {
          name: group[:name],
          color: group[:color],
          classification: group[:classification],
          value: group[:values_by_date][value.date] || Money.new(0, family.currency)
        }
      end

      # Built by hand rather than through `Series#as_json`, so it needs the same
      # display rounding: the chart is drawn from the amount, and a sub-unit
      # residue would plot as a visible move between two points that print the
      # same value. The classification totals are left alone, since only their
      # formatted string is rendered.
      current = value.value.for_display
      previous_value = (previous&.value || value.value).for_display

      {
        date: value.date,
        date_formatted: value.date_formatted,
        value: current,
        # Month-over-month change between chart points. The trend on the raw
        # series value compares the underlying balance row's own start/end,
        # which at a monthly interval reflects only the last balance update
        # before the sample date. The first point has no prior month, so it
        # gets a flat trend.
        trend: Trend.new(
          current: current,
          previous: previous_value,
          favorable_direction: "up"
        ),
        assets: classification_total(point_groups, "asset"),
        liabilities: classification_total(point_groups, "liability"),
        groups: point_groups
      }
    end

    def classification_total(point_groups, classification)
      total = point_groups
        .select { |group| group[:classification] == classification }
        .sum { |group| group[:value].amount }

      Money.new(total, family.currency)
    end

    def group_series(period, group_by)
      grouped_accounts(group_by).filter_map do |group|
        direction = group[:classification] == "asset" ? "up" : "down"
        series = series_for(group[:accounts], favorable_direction: direction, period: period)
        values_by_date = series.values.index_by(&:date).transform_values(&:value)

        next if values_by_date.values.all? { |money| money.amount.zero? }

        group.except(:accounts).merge(values_by_date: values_by_date)
      end
    end

    def grouped_accounts(group_by)
      return grouped_by_account_type if group_by == AccountGrouping::DEFAULT_PRIMARY

      grouping = AccountGrouping.new(group_by, user: user)

      %w[asset liability].flat_map do |classification|
        accounts = historical_accounts.select { |account| account.classification == classification }

        grouping.group(accounts).map do |group|
          key = AccountGrouping.classified_group_key(classification, group_by, group.key)
          { name: group.name, color: AccountGrouping.color_for(key), classification: classification, accounts: group.accounts }
        end
      end
    end

    def grouped_by_account_type
      historical_accounts
        .group_by { |account| [ account.classification, Accountable.from_type(account.accountable_type) ] }
        .sort_by do |(classification, accountable), _accounts|
          [
            classification == "asset" ? 0 : 1,
            Accountable::TYPES.index(accountable.name) || Float::INFINITY
          ]
        end
        .map do |(classification, accountable), accounts|
          { name: accountable.display_name, color: accountable.color, classification: classification, accounts: accounts }
        end
    end

    def series_for(accounts, favorable_direction:, period:)
      Balance::ChartSeriesBuilder.new(
        account_ids: accounts.map(&:id),
        account_active_until_dates: disabled_account_active_until_dates(accounts),
        currency: family.currency,
        period: period,
        interval: INTERVAL,
        favorable_direction: favorable_direction
      ).balance_series
    end

    def historical_accounts
      # Preloads what AccountGrouping reads (provider, owner, tax treatment).
      @historical_accounts ||= BalanceSheet::HistoricalAccountScope.new(family, user: user).relation
        .includes(:accountable, :owner, :plaid_account, :simplefin_account, account_providers: :provider)
        .to_a
    end

    def disabled_account_active_until_dates(accounts)
      accounts.each_with_object({}) do |account, dates|
        next unless account.disabled?

        disabled_on = (account.disabled_at || account.updated_at).to_date
        dates[account.id] = disabled_on - 1.day
      end
    end

    def cache_key(period, group_by)
      shares_version = user ? AccountShare.where(user: user).maximum(:updated_at)&.to_i : nil
      # Owner groups are named after users, so a renamed user must refresh them.
      owner_names_version = family.users.maximum(:updated_at)&.to_f if group_by == "owner"
      key = [
        "balance_sheet_net_worth_breakdown_series",
        CACHE_VERSION,
        user&.id,
        shares_version,
        owner_names_version,
        period.start_date,
        period.end_date,
        group_by
      ].compact.join("_")

      family.build_cache_key(
        key,
        invalidate_on_data_updates: true
      )
    end
end
