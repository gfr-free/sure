# frozen_string_literal: true

require "test_helper"

# Enter in a picker's search box follows one rule (utils/search_match):
# it never submits the surrounding form, creates while a create row shows,
# and otherwise picks the typed name's match. Page searches and filter
# popovers with an "Apply" button keep Enter as submit on purpose.
class SearchEnterTest < ActiveSupport::TestCase
  # A search box that filters a picker list as you type.
  LIST_SEARCH = /action[:=]\s*["'](?:input->)?(?:list-filter|[\w-]+-select)#filter\b[^"']*["']/

  # path => why Enter there is not the picker rule.
  ENTER_SUBMITS = {
    "app/views/transactions/searches/filters/_account_filter.html.erb" => "filter popover: Enter applies the filter",
    "app/views/transactions/searches/filters/_category_filter.html.erb" => "filter popover: Enter applies the filter",
    "app/views/transactions/searches/filters/_merchant_filter.html.erb" => "filter popover: Enter applies the filter",
    "app/views/transactions/searches/filters/_tag_filter.html.erb" => "filter popover: Enter applies the filter",
    "app/views/pages/dashboard/_filter_popover.html.erb" => "filter popover: Enter applies the filter",
    "app/components/DS/select.html.erb" => "select_controller handles Enter from its search box (shared rule)",
    "app/components/DS/icon_picker.html.erb" => "icon grid: Enter only filters (keydown.enter prevented)",
    "app/views/transactions/categorizes/show.html.erb" => "categorize_controller handles Enter page-wide (shared rule)"
  }.freeze

  test "picker search boxes handle Enter" do
    offenders = list_search_lines.filter_map do |path, number, line|
      next if line.include?("keydown")
      next if ENTER_SUBMITS.key?(path)

      "#{path}:#{number}"
    end

    assert_empty offenders, <<~MESSAGE
      A search box that filters a picker list needs keydown->list-filter#handleKeydown
      (or its picker's handleSearchKeydown), so Enter picks instead of submitting.
      If Enter should submit there, add the file to ENTER_SUBMITS with the reason.
    MESSAGE
  end

  test "every exception still has a list search box" do
    paths = list_search_lines.map(&:first)
    assert_empty ENTER_SUBMITS.keys - paths, "Remove ENTER_SUBMITS entries whose search box is gone."
  end

  test "controllers that filter a list use the shared Enter rule" do
    controllers = Dir[Rails.root.join("app/javascript/controllers/**/*.js")].sort.filter_map do |file|
      source = File.read(file)
      next unless source.match?(/\bmatchesSearch\b/) ||
        file.end_with?("/select_controller.js", "/categorize_controller.js")
      next if source.include?("isConfirmingEnter")

      Pathname(file).relative_path_from(Rails.root).to_s
    end

    assert_empty controllers, "Handle Enter with isConfirmingEnter and enterMatch from utils/search_match."
  end

  private
    def list_search_lines
      Dir[Rails.root.join("app/{views,components}/**/*.erb")].sort.flat_map do |file|
        path = Pathname(file).relative_path_from(Rails.root).to_s
        File.readlines(file).each_with_index.filter_map do |line, index|
          [ path, index + 1, line ] if line.match?(LIST_SEARCH)
        end
      end
    end
end
