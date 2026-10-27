require "test_helper"

# Family admins can switch Budgets and the Plan hub (Plan + Goals) off in
# Settings -> Preferences. Covers every web surface the switches gate; the API,
# assistant and insights sides live next to their own tests.
class PlanningFeatureTogglesTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @family = @admin.family
    sign_in @admin
    ensure_tailwind_build
  end

  test "admin switches budgets and plan off from preferences" do
    patch user_url(@admin), params: {
      user: {
        redirect_to: "preferences",
        family_attributes: { id: @family.id, budgets_enabled: "0", plan_enabled: "0" }
      }
    }

    assert_redirected_to settings_preferences_url
    @family.reload
    assert_not @family.budgets_enabled?
    assert_not @family.plan_enabled?
  end

  test "member cannot switch budgets off" do
    sign_in member = users(:family_member)

    patch user_url(member), params: {
      user: {
        redirect_to: "preferences",
        family_attributes: { id: member.family.id, budgets_enabled: "0" }
      }
    }

    assert_redirected_to settings_profile_url
    assert_equal I18n.t("users.reset.unauthorized"), flash[:alert]
    assert member.family.reload.budgets_enabled?
  end

  test "preferences show the switches to admins only" do
    enable_preview(@admin)

    get settings_preferences_url
    assert_select "input[name='user[family_attributes][budgets_enabled]']"
    assert_select "input[name='user[family_attributes][plan_enabled]']"

    sign_in users(:family_member)
    get settings_preferences_url
    assert_select "input[name='user[family_attributes][budgets_enabled]']", count: 0
  end

  test "plan switch needs the preview flag, since goals do too" do
    get settings_preferences_url

    assert_select "input[name='user[family_attributes][budgets_enabled]']"
    assert_select "input[name='user[family_attributes][plan_enabled]']", count: 0
  end

  test "budgets off removes the nav entry and closes the budget pages" do
    @family.update!(budgets_enabled: false)

    get root_url
    assert_select "a[href='#{budgets_path}']", count: 0

    get budgets_url
    assert_redirected_to root_url
    assert_equal I18n.t("planning_features.budgets_disabled"), flash[:alert]

    budget = Budget.find_or_bootstrap(@family, start_date: Date.current, user: @admin)
    get budget_url(budget)
    assert_redirected_to root_url

    get budget_budget_categories_url(budget)
    assert_redirected_to root_url
  end

  test "budgets off blocks budget sharing changes" do
    @family.update!(budgets_enabled: false)
    member = users(:family_member)

    assert_no_difference "BudgetShare.count" do
      patch settings_budget_shares_url, params: {
        budget_shares: { members: { "0" => { viewer_id: member.id, permission: "read_only" } } }
      }
    end
    assert_redirected_to root_url
  end

  test "budgets on keeps the nav entry for users without preview" do
    get root_url

    assert_select "a[href='#{budgets_path}']"
  end

  test "plan hub without budgets shows only the goals" do
    enable_preview(@admin)
    @family.update!(budgets_enabled: false)

    get root_url
    assert_select "a[href='#{plan_path}']"

    get plan_url
    assert_response :success
    assert_select "a[href^='/budgets']", count: 0
  end

  test "plan off falls back to the budgets entry and closes plan and goals" do
    enable_preview(@admin)
    @family.update!(plan_enabled: false)

    get root_url
    assert_select "a[href='#{plan_path}']", count: 0
    assert_select "a[href='#{budgets_path}']"

    get plan_url
    assert_redirected_to budgets_url

    get goals_url
    assert_redirected_to root_url
    assert_equal I18n.t("planning_features.plan_disabled"), flash[:alert]

    get goal_url(goals(:emergency_fund))
    assert_redirected_to root_url
  end

  test "both off leaves no planning entry and sends plan home" do
    enable_preview(@admin)
    @family.update!(budgets_enabled: false, plan_enabled: false)

    get root_url
    assert_select "a[href='#{plan_path}']", count: 0
    assert_select "a[href='#{budgets_path}']", count: 0

    get plan_url
    assert_redirected_to root_url
  end

  test "budget page hides the goals panel while plan is off" do
    enable_preview(@admin)
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current, user: @admin)

    get budget_url(budget)
    assert_select "a[href='#{goals_path}']"

    @family.update!(plan_enabled: false)
    get budget_url(budget)
    assert_select "a[href='#{goals_path}']", count: 0
  end

  test "reports drop the budget card while budgets are off" do
    get reports_url
    assert_includes response.body, I18n.t("reports.summary.budget_performance")

    @family.update!(budgets_enabled: false)
    get reports_url
    assert_response :success
    assert_not_includes response.body, I18n.t("reports.summary.budget_performance")
  end

  private
    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end
end
