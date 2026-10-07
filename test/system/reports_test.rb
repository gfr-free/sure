require "application_system_test_case"

class ReportsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    visit reports_path(period_type: :monthly)

    # The tooltip only shows once the page's controllers are connected, so
    # keys pressed after this reach an installed hotkey.
    find("a[aria-keyshortcuts='ArrowLeft']").hover
    assert_selector "[role='tooltip']", text: "Previous period (←)"

    # Record the links the hotkeys click instead of following them. A hotkey
    # clicks synchronously, so the list is complete when the key returns.
    page.execute_script(<<~JS)
      window.clickedHotkeys = [];
      document.addEventListener("click", (event) => {
        const link = event.target.closest("a[data-hotkey]");
        if (!link) return;
        window.clickedHotkeys.push(link.dataset.hotkey);
        event.preventDefault();
      }, true);
    JS
  end

  test "the arrow keys leave section moves and dialogs alone" do
    find("section[data-section-key]", match: :first).send_keys(:enter)
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys
    page.send_keys(:escape)

    click_link I18n.t("reports.transactions_breakdown.export.google_sheets")
    assert_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys

    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  test "a held arrow key steps one period" do
    page.execute_script(<<~JS)
      for (const repeat of [false, true, true]) {
        document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", repeat, bubbles: true }));
      }
    JS

    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  test "a section moved with the keyboard keeps its new place" do
    first, second = all("section[data-section-key]").first(2).map { |section| section["data-section-key"] }
    record_saved_section_order("reports-sortable")

    find("section[data-section-key='#{first}']").send_keys(:enter)
    page.send_keys(:arrow_down)
    page.send_keys(:enter)

    assert_selector "html[data-order-saved='200']"
    saved_order = users(:family_admin).reload.reports_section_order
    assert_operator saved_order.index(second), :<, saved_order.index(first)
  end

  test "Enter on a link inside a section follows the link" do
    link = find_link(I18n.t("reports.transactions_breakdown.export.google_sheets"))
    section = link.find(:xpath, "ancestor::section[@data-section-key]")

    link.send_keys(:enter)

    assert_selector "dialog[open]"
    assert_equal "false", section["aria-grabbed"]
  end

  test "a cancelled touch does not leave a section held" do
    section = find("section[data-section-key]", match: :first)

    page.execute_script(<<~JS, section)
      const section = arguments[0];
      const touch = new Touch({ identifier: 1, target: section, clientX: 10, clientY: 10 });
      section.dispatchEvent(new TouchEvent("touchstart", { touches: [touch], bubbles: true }));
      section.dispatchEvent(new TouchEvent("touchcancel", { touches: [], bubbles: true }));
    JS
    sleep 0.3 # past the 150 ms hold delay

    assert_equal "false", section["aria-grabbed"]
    assert_not_includes section[:class], "opacity-50"
  end

  test "a section still grabbed when the page changes keeps its new place" do
    first, second = all("section[data-section-key]").first(2).map { |section| section["data-section-key"] }
    record_saved_section_order("reports-sortable")

    find("section[data-section-key='#{first}']").send_keys(:enter)
    page.send_keys(:arrow_down)
    page.execute_script("document.querySelector(\"[data-controller~='reports-sortable']\").remove()")

    assert_selector "html[data-order-saved='200']"
    saved_order = users(:family_admin).reload.reports_section_order
    assert_operator saved_order.index(second), :<, saved_order.index(first)
  end

  private
    def clicked_hotkeys
      page.evaluate_script("window.clickedHotkeys")
    end
end
