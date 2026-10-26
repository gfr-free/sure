require "application_system_test_case"

class DialogClickOutsideTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    visit transactions_url
    click_on I18n.t("transactions.index.new_transaction")
    assert_selector "turbo-frame#modal dialog[open]"
  end

  # A drag across the content's edge, such as selecting text, still ends in a
  # click outside it.
  test "only a click that starts and ends outside the content closes the dialog" do
    press_and_release from: :inside, to: :outside
    assert_selector "turbo-frame#modal dialog[open]"

    press_and_release from: :outside, to: :inside
    assert_selector "turbo-frame#modal dialog[open]"

    press_and_release from: :outside, to: :outside
    assert_no_selector "dialog[open]"
  end

  test "a keyboard click on a control that removes itself keeps the dialog open" do
    page.execute_script(<<~JS)
      const button = document.createElement("button");
      button.type = "button";
      button.id = "remove-me";
      button.textContent = "Remove";
      button.addEventListener("click", () => button.remove());
      document.querySelector("turbo-frame#modal dialog[open] h2").after(button);
      button.focus();
    JS

    find("#remove-me").send_keys(:enter)
    assert_no_selector "#remove-me"
    assert_selector "turbo-frame#modal dialog[open]"
  end

  private
    def press_and_release(from:, to:)
      actions = page.driver.browser.action
      point(actions, from).click_and_hold
      point(actions, to).release.perform
    end

    def point(actions, where)
      if where == :inside
        actions.move_to(find("turbo-frame#modal dialog[open] h2").native)
      else
        actions.move_to_location(5, 5)
      end
    end
end
