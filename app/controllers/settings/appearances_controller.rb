class Settings::AppearancesController < ApplicationController
  layout "settings"

  # Renders the user's appearance settings page (the form for #update).
  def show
    @user = Current.user
  end

  # Updates the submitted Appearance preferences under a pessimistic
  # user-row lock. Account-group selections are filtered to known accountable
  # keys; preferences omitted from the form are preserved as-is.
  def update
    @user = Current.user
    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      updated_prefs["show_split_grouped"] = params.dig(:user, :show_split_grouped) == "1" if params.dig(:user, :show_split_grouped)
      updated_prefs["dashboard_two_column"] = params.dig(:user, :dashboard_two_column) == "1" if params.dig(:user, :dashboard_two_column)
      updated_prefs["disable_modal_click_outside"] = params.dig(:user, :disable_modal_click_outside) == "1" if params.dig(:user, :disable_modal_click_outside)
      # "Always expand" account groups on the dashboard balance sheet. The form
      # posts one checkbox per accountable type; unchecked boxes are hidden
      # fields that submit an empty string, so when the checkboxes are in the
      # form the param is always present (an array, possibly empty). We only
      # write it when present so a form that omits the checkboxes (e.g. a
      # two-column-only form) never wipes the stored selection.
      if (account_groups = params.dig(:user, :account_groups))
        # Unchecked boxes arrive as empty strings (one per hidden field); keep
        # only the actually-selected keys, and validate against known types so
        # arbitrary strings can't be injected into the JSONB column.
        valid_keys = Accountable::TYPES.map(&:underscore)
        selected = (account_groups.is_a?(Array) ? account_groups : [ account_groups ])
        updated_prefs["always_expanded_account_groups"] = selected.select { |k| valid_keys.include?(k) }
      end
      # Second grouping level for the account lists. Blank means "type only";
      # anything outside the known dimensions is dropped.
      AccountGrouping::VIEWS.each do |view|
        param_key = :"account_grouping_#{view}"
        next unless params.dig(:user, param_key)

        dimension = params.dig(:user, param_key).to_s
        updated_prefs["account_grouping"] = (updated_prefs["account_grouping"] || {}).merge(
          view => (AccountGrouping.valid_dimension?(dimension) ? dimension : nil)
        ).compact
      end
      if (label = params.dig(:user, :custom_account_group_label))
        updated_prefs["custom_account_group_label"] = label.to_s.squish.first(AccountGrouping::CUSTOM_GROUP_MAX_LENGTH).presence
        updated_prefs.delete("custom_account_group_label") if updated_prefs["custom_account_group_label"].nil?
      end
      @user.update!(preferences: updated_prefs)
    end
    redirect_to settings_appearance_path
  end
end
