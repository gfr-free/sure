require "application_system_test_case"

# A tap is pointerdown, pointerup, pointerleave with no pointermove between
# them, so a chart that only listens for pointermove and hides on pointerleave
# never shows its tooltip to a finger. Only a browser dispatching real touch
# input can say which pointer events a tap produces.
class GoalProjectionChartTouchTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    # Goals sit behind the preview gate; without it the visit redirects to the
    # dashboard and the chart never renders.
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  test "a tap shows the tooltip and a tap outside the chart closes it" do
    # Out of reach, so the panel draws the projection chart rather than the
    # "goal reached" celebration.
    goal = goals(:vacation_italy)
    goal.update!(target_amount: 50_000)
    visit goal_path(goal)

    x, y = plot_center
    tap_at(x, y)
    assert_selector "[data-controller='goal-projection-chart'] .chart-tooltip", visible: true

    heading = find("h1", text: goal.name).native.rect
    tap_at(heading.x + heading.width / 2, heading.y + heading.height / 2)
    assert_no_selector "[data-controller='goal-projection-chart'] .chart-tooltip", visible: true
  end

  test "a mouse still hides the tooltip when it leaves the chart" do
    goal = goals(:vacation_italy)
    goal.update!(target_amount: 50_000)
    visit goal_path(goal)

    plot_center
    find("[data-controller='goal-projection-chart'] svg rect[fill='transparent']").hover
    assert_selector "[data-controller='goal-projection-chart'] .chart-tooltip", visible: true

    find("h1", text: goal.name).hover
    assert_no_selector "[data-controller='goal-projection-chart'] .chart-tooltip", visible: true
  end

  private

    # Center of the transparent hover overlay, in viewport pixels, once the
    # chart has drawn and been scrolled into view.
    def plot_center
      assert_selector "[data-controller='goal-projection-chart'] svg rect[fill='transparent']"
      page.evaluate_script(<<~JS)
        (() => {
          const overlay = document.querySelector("[data-controller='goal-projection-chart'] svg rect[fill='transparent']");
          overlay.scrollIntoView({ block: "center" });
          const rect = overlay.getBoundingClientRect();
          return [rect.left + rect.width / 2, rect.top + rect.height / 2];
        })()
      JS
    end

    def tap_at(x, y)
      browser = page.driver.browser
      browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ { x: x, y: y } ])
      browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
    end
end
