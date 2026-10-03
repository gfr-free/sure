require "test_helper"

class Settings::AppearancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    sign_in @user
  end

  test "shows the account list settings to preview users only" do
    get settings_appearance_path
    assert_select "select[name='user[account_grouping_sidebar]']"

    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    get settings_appearance_path
    assert_select "select[name='user[account_grouping_sidebar]']", count: 0
  end

  test "stores a valid grouping dimension per view and drops unknown ones" do
    patch settings_appearance_path, params: { user: { account_grouping_sidebar: "institution", account_grouping_dashboard: "custom_group" } }
    assert_redirected_to settings_appearance_path

    @user.reload
    assert_equal "institution", @user.account_grouping_for(:sidebar)
    assert_equal "custom_group", @user.account_grouping_for(:dashboard)

    patch settings_appearance_path, params: { user: { account_grouping_sidebar: "name; drop table" } }
    @user.reload
    assert_nil @user.account_grouping_for(:sidebar)
    assert_equal "custom_group", @user.account_grouping_for(:dashboard)

    patch settings_appearance_path, params: { user: { account_grouping_dashboard: "" } }
    assert_nil @user.reload.account_grouping_for(:dashboard)
  end

  test "keeps other preferences when saving the grouping" do
    @user.update!(preferences: @user.preferences.merge("always_expanded_account_groups" => [ "depository" ]))

    patch settings_appearance_path, params: { user: { account_grouping_sidebar: "currency" } }

    assert_equal [ "depository" ], @user.reload.always_expanded_account_groups
  end

  test "renames the custom group field and resets it when blank" do
    patch settings_appearance_path, params: { user: { custom_account_group_label: "  Purpose " } }
    assert_equal "Purpose", @user.reload.custom_account_group_label

    patch settings_appearance_path, params: { user: { custom_account_group_label: "" } }
    assert_equal I18n.t("account_grouping.dimensions.custom_group"), @user.reload.custom_account_group_label
  end

  test "renders the second level in the sidebar and on the dashboard" do
    accounts(:depository).update!(institution_name: "ING")
    @user.update!(preferences: @user.preferences.merge("account_grouping" => { "sidebar" => "institution", "dashboard" => "institution" }))

    get root_path

    assert_response :success
    assert_select "#account-sidebar-tabs [data-subgroup-key='ing']"
    assert_select "#balance-sheet [data-subgroup-key='ing']"
  end

  test "ignores the stored grouping without preview access" do
    accounts(:depository).update!(institution_name: "ING")
    @user.update!(preferences: @user.preferences.merge(
      "preview_features_enabled" => false,
      "account_grouping" => { "sidebar" => "institution", "dashboard" => "institution" }
    ))

    get root_path

    assert_response :success
    assert_select "[data-subgroup-key]", count: 0
  end
end
