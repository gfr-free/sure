require "application_system_test_case"

class PeriodPickerCustomRangeTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)

    @start_date = 20.days.ago.to_date
    @end_date = 3.days.ago.to_date
    @custom_label = Period.custom(start_date: @start_date, end_date: @end_date).label_range
  end

  test "a custom range picked on the dashboard drives its sections and the address bar" do
    default_period = users(:family_admin).default_period
    visit root_path

    apply_custom_range

    assert_selector period_button(@custom_label)
    assert_current_path "#{root_path}?start_date=#{@start_date}&end_date=#{@end_date}"
    assert_equal default_period, users(:family_admin).reload.default_period
  end

  test "a custom range picked on an account page re-renders that account's chart" do
    account = accounts(:depository)
    visit account_path(account)
    assert_selector "main h2", text: account.name

    apply_custom_range

    assert_selector period_button(@custom_label)
    assert_current_path "#{account_path(account)}?start_date=#{@start_date}&end_date=#{@end_date}"
  end

  test "cancel closes the dialog and returns focus to the picker" do
    visit root_path
    open_custom_range_dialog

    within("dialog[open]") { click_button I18n.t("UI.period_picker.custom_range.cancel") }

    assert_no_selector "dialog[open]"
    assert_selector "#{period_button("30D")}:focus"
  end

  private
    def period_button(label)
      "button[aria-label='#{I18n.t("UI.period_picker.aria_label", period: label)}']"
    end

    def open_custom_range_dialog
      find("button[aria-label^='#{I18n.t("UI.period_picker.aria_label", period: "")}']").click
      click_link I18n.t("UI.period_picker.custom_range.open")
      assert_selector "dialog[open]"
    end

    def apply_custom_range
      open_custom_range_dialog
      within("dialog[open]") do
        fill_in_date I18n.t("UI.period_picker.custom_range.start_date"), @start_date
        fill_in_date I18n.t("UI.period_picker.custom_range.end_date"), @end_date
        click_button I18n.t("UI.period_picker.custom_range.apply")
      end
    end

    # Typing into a native date input depends on the browser's locale format;
    # setting the value directly and firing change is what the picker reacts to.
    def fill_in_date(label, date)
      field = find_field(label)
      execute_script("arguments[0].value = arguments[1]; arguments[0].dispatchEvent(new Event('change', { bubbles: true }))", field, date.to_s)
    end
end
