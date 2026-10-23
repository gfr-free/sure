module AccountsHelper
  def summary_card(title:, &block)
    content = capture(&block)
    render "accounts/summary_card", title: title, content: content
  end

  def sync_path_for(account)
    # Always use the account sync path, which handles syncing all providers
    sync_account_path(account)
  end

  # How long a sidebar sparkline frame may spend fetching before
  # `turbo_frame_timeout_controller` replaces it with a warning badge.
  SPARKLINE_FRAME_TIMEOUT_MS = 10_000

  # Shared by the group-level and the per-account sparkline frames so the two
  # call sites cannot drift apart.
  #
  # Those frames are `loading: "lazy"`: Turbo fetches them when they scroll
  # into view, which can be long after they render, or never, so the countdown
  # has to time the request rather than the element. The frames declare when it
  # starts and when it stops.
  def sparkline_frame_data
    {
      controller: "turbo-frame-timeout",
      action: "turbo:before-fetch-request->turbo-frame-timeout#startTimeout " \
              "turbo:frame-load->turbo-frame-timeout#clearTimeout",
      turbo_frame_timeout_timeout_value: SPARKLINE_FRAME_TIMEOUT_MS
    }
  end

  # Returns the account id segment from `/accounts/<id>(/...)?`, or nil.
  # Used as a cache-key component so the sidebar's active-link styling is
  # correct without busting the cache for every unrelated path change.
  def sidebar_active_account_id
    match = request.path.match(%r{\A/accounts/([\w-]+)})
    match && match[1]
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
      family.build_cache_key("account_sidebar_tabs_v6", invalidate_on_data_updates: true),
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
      # Changing the account order, or dragging an account in the manual
      # order, must re-render the sidebar right away rather than after the
      # 12h expiry.
      Current.user&.default_account_order,
      Current.user&.account_order&.manual? ? Digest::SHA256.hexdigest([ Current.user.manual_account_order, Current.user.preferences&.dig("manual_list_order") ].to_json) : nil,
      account_grouping_primary(:sidebar),
      account_grouping_dimension(:sidebar)
    ]
  end

  # The first grouping dimension for an account list view (default: account
  # type). Preview-only for now.
  def account_grouping_primary(view)
    return AccountGrouping::DEFAULT_PRIMARY unless Current.user&.preview_features_enabled?

    Current.user.account_grouping_primary_for(view)
  end

  # First-level account groups of a balance sheet or one of its
  # classification groups, as chosen for the given view.
  def account_groups_for(source, view:)
    source.account_groups(by: account_grouping_primary(view), user: Current.user)
  end

  # Sections of the sidebar's "All" tab as [classification group, account
  # groups], one per side, so each side's groups can be reordered on their
  # own. Grouped by another field than the account type, the same value
  # (e.g. "Not set" or one owner) forms a group among assets and among debts,
  # so the sections get headings (see account_group_section_headings?)
  # instead of showing two rows with one name.
  def account_group_sections_for(balance_sheet, view:)
    balance_sheet.classification_groups.filter_map do |classification_group|
      groups = account_groups_for(classification_group, view: view)
      [ classification_group, groups ] if groups.any?
    end
  end

  # Grouped by account type, every group belongs to one side, so the "All"
  # tab reads as one flat list.
  def account_group_section_headings?(view)
    account_grouping_primary(view) != AccountGrouping::DEFAULT_PRIMARY
  end

  # The second grouping dimension for an account list view, or nil when the
  # view groups by account type only. Preview-only for now. Reads the flag
  # from Current.user so the helper also works outside a controller render.
  def account_grouping_dimension(view)
    return nil unless Current.user&.preview_features_enabled?

    Current.user&.account_grouping_for(view)
  end

  # With the manual order, accounts, groups and subgroups can be dragged in
  # every grouping; each dimension keeps its own order.
  def account_sidebar_sortable?
    Current.user&.account_order&.manual? || false
  end

  # Data attributes of one of the sidebar's sortable lists. list is the name
  # the shared sortable-list controller runs under; each nesting level
  # (groups, subgroups, accounts) needs its own (see
  # sortable_list_controller.js). Copies of a list in other tabs share the
  # url and mirror each move.
  def sidebar_sortable_list_data(list, url:, param:)
    prefix = list.underscore
    {
      controller: list,
      "#{prefix}_url_value": url,
      "#{prefix}_param_value": param,
      "#{prefix}_hold_delay_value": 400,
      "#{prefix}_save_timeout_value": 10_000,
      "#{prefix}_mirror_lists_value": true,
      action: "dragover->#{list}#dragOver drop->#{list}#drop account-sort-mode:stop@window->#{list}#releaseKeyboardGrab turbo:before-visit@window->#{list}#saveBeforeVisit"
    }
  end

  # Data attributes of a row in one of those lists. Rows of every level
  # carry their id in data-sortable-list-id.
  def sidebar_sortable_item_data(list, id)
    {
      "#{list.underscore}_target": "item",
      sortable_list_id: id,
      action: "dragstart->#{list}#dragStart dragend->#{list}#dragEnd"
    }
  end

  # Subgroups to render inside a first-level group for the given view, or
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
