module AccountsHelper
  def summary_card(title:, &block)
    content = capture(&block)
    render "accounts/summary_card", title: title, content: content
  end

  def sync_path_for(account)
    # Always use the account sync path, which handles syncing all providers
    sync_account_path(account)
  end

  # Returns the account id segment from `/accounts/<id>(/...)?`, or nil.
  # Used as a cache-key component so the sidebar's active-link styling is
  # correct without busting the cache for every unrelated path change.
  def sidebar_active_account_id
    match = request.path.match(%r{\A/accounts/([\w-]+)})
    match && match[1]
  end

  # Unread (synced or imported, not yet seen) transactions per account for the
  # sidebar badges. One grouped query per request, shared by every render of
  # the sidebar (desktop and mobile).
  def sidebar_unread_counts
    @sidebar_unread_counts ||= Current.user ? Current.user.unread_entry_counts_by_account : {}
  end

  # Cache key for `accounts/_account_sidebar_tabs.html.erb`.
  # Kept here (not in the ERB) so the partial stays render-only.
  #
  # `shares_version` includes both row count and `max(updated_at)` because
  # deleting a non-most-recent share would not move `max(updated_at)` and
  # could otherwise serve stale fragments to a user who lost access.
  # Both are pulled in a single SQL round-trip via `pick`. Note: Rails
  # returns the values as Strings for raw SQL fragments — that's fine
  # since they only feed into a cache key (concat-stable, never coerced).
  def account_sidebar_tabs_cache_key(family:, active_tab:, mobile:)
    shares_version =
      if Current.user
        count, max_at = AccountShare
          .where(user_id: Current.user.id)
          .pick(Arel.sql("count(*)"), Arel.sql("max(updated_at)"))
        "#{count}-#{max_at}"
      end

    [
      family.build_cache_key("account_sidebar_tabs_v4", invalidate_on_data_updates: true),
      Current.user&.id,
      shares_version,
      active_tab,
      mobile,
      I18n.locale,
      sidebar_active_account_id,
      # Fold the per-user "start expanded by default" preference into the key
      # so toggling it in Settings busts the 12h fragment cache immediately
      # (this partial renders with skip_digest: true, so the template digest
      # would not otherwise reflect the change).
      Current.user&.always_expanded_account_groups&.sort,
      # Unread badges change whenever a list render marks rows read.
      Digest::SHA256.hexdigest(sidebar_unread_counts.sort.to_json),
      account_grouping_dimension(:sidebar)
    ]
  end

  # Data version for the sidebar's sparkline frames. It is built from the same
  # inputs as the sparkline ETags (latest sync + account updates), so it moves
  # exactly when a sparkline could change. Computed once per sidebar render.
  def sidebar_sparkline_version(family)
    # Per user and share version too: which accounts a group sparkline covers
    # depends on the viewer's account shares.
    key = [
      family.build_cache_key("sidebar_sparklines_#{Account::Chartable::SPARKLINE_CACHE_VERSION}", invalidate_on_data_updates: true),
      Current.user&.id,
      Current.account_share_version
    ].join("_")
    Digest::SHA256.hexdigest(key).first(12)
  end

  # DOM id for a sparkline frame in the sidebar. The sidebar renders each group
  # and account up to four times (All tab + type tab, desktop + mobile), so the
  # id carries the placement to stay unique. The frames are
  # data-turbo-permanent: a loaded sparkline survives Turbo navigations while
  # its id is unchanged, and the data version in the id makes a sync render new
  # frames that load fresh.
  def sidebar_sparkline_frame_id(base_id, all_tab:, mobile:, version:)
    [ ("mobile" if mobile), (all_tab ? "all" : "tab"), base_id, version ].compact.join("_")
  end

  # Frame id for a sparkline response: echoes the requesting frame's id so
  # Turbo can match it, falling back to the base id for direct requests.
  def sparkline_response_frame_id(base_id)
    requested = turbo_frame_request_id.to_s
    pattern = /\A(?:mobile_)?(?:all|tab)_#{Regexp.escape(base_id)}_[0-9a-f]{12}\z/
    requested.match?(pattern) ? requested : base_id
  end

  # The second grouping dimension for an account list view, or nil when the
  # view groups by account type only. Preview-only for now. Reads the flag
  # from Current.user so the helper also works outside a controller render.
  def account_grouping_dimension(view)
    return nil unless Current.user&.preview_features_enabled?

    Current.user&.account_grouping_for(view)
  end

  # Subgroups to render inside an account type group for the given view, or
  # an empty array when the view has no second level (see AccountGrouping).
  def account_subgroups(account_group, view:)
    dimension = account_grouping_dimension(view)
    return [] unless dimension

    account_group.subgroups(dimension, user: Current.user)
  end

  # Values already used for the custom group field on accounts the user can
  # see, offered as suggestions in the account form.
  def account_custom_group_suggestions
    return [] unless Current.user

    Current.user.accessible_accounts
      .where.not(custom_group: nil)
      .distinct
      .order(:custom_group)
      .pluck(:custom_group)
  end
end
