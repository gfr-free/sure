# Family-level switches for Budgets and the Plan hub (Plan + Goals). A family
# admin turns either off in Settings -> Preferences; the surfaces then drop out
# of the nav and every page of the feature sends the user home, the way the
# Bills toggle does. The data stays, so turning a feature back on restores it.
module PlanningFeatureGuardable
  extend ActiveSupport::Concern

  included do
    helper_method :plan_hub_visible?
  end

  private
    # Goals and the hub itself only exist behind the preview flag, so the
    # family switch narrows that gate rather than replacing it.
    def plan_hub_visible?
      preview_features_enabled? && Current.family&.plan_enabled? == true
    end

    def ensure_budgets_enabled
      return if Current.family.budgets_enabled?

      redirect_to root_path, alert: t("planning_features.budgets_disabled")
    end

    def ensure_plan_enabled
      return if Current.family.plan_enabled?

      redirect_to root_path, alert: t("planning_features.plan_disabled")
    end
end
