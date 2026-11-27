# frozen_string_literal: true

require "test_helper"

# Every picker searches its list the same way: accents and case ignored,
# each typed word matched on its own, and "create" offered only when no
# existing name matches. That rule lives in utils/search_match.mjs; a picker
# that compares the typed text itself drifts from the others.
class SearchMatchUsageTest < ActiveSupport::TestCase
  CONTROLLERS = "app/javascript/controllers/**/*.js"

  # Lowercasing the typed text or a row's name in place of normalizeSearchText.
  OWN_COMPARISON = /(?:searchTarget\.value|dataset\.(?:filterName|tagName|merchantName|categoryName))[^;]*\.(?:toLowerCase|toLocaleLowerCase)\(/

  test "pickers with a search box filter through search_match" do
    offenders = controller_files.filter_map do |path, source|
      targets = source[/static\s+targets\s*=\s*\[(.*?)\]/m, 1].to_s
      next unless targets.include?('"option"') && targets.include?('"search"')
      next if source.include?('from "utils/search_match"')

      path
    end

    assert_empty offenders, "A picker with option and search targets imports matchesSearch/namesExactly from utils/search_match."
  end

  test "no controller compares typed search text on its own" do
    offenders = controller_files.filter_map do |path, source|
      path if joined_chains(source).lines.any? { |line| line.match?(OWN_COMPARISON) }
    end

    assert_empty offenders, "Use matchesSearch / namesExactly from utils/search_match instead of lowercasing the query."
  end

  test "the guard recognizes the comparisons it forbids" do
    [
      "const query = this.searchTarget.value.trim().toLowerCase();",
      'const name = (option.dataset.filterName || "").toLowerCase();',
      "const name = option.dataset.tagName.toLowerCase();",
      "const query = this.searchTarget.value\n      .trim()\n      .toLowerCase();",
      "const name = (\n  option.dataset.filterName || \"\"\n).toLowerCase();",
      "const name = (\n  option.dataset.filterName ||\n  \"\"\n).toLowerCase();"
    ].each { |sample| assert_match OWN_COMPARISON, joined_chains(sample) }
  end

  private
    # Biome wraps long method chains and parenthesized operands; put each
    # back on one line.
    def joined_chains(source)
      source.gsub(/\n\s*(?=[.)])/, "").gsub(/(\(|\|\||&&|\?\?)\s*\n\s*/, '\\1 ')
    end

    def controller_files
      Dir[Rails.root.join(CONTROLLERS)].sort.map do |file|
        [ Pathname(file).relative_path_from(Rails.root).to_s, File.read(file) ]
      end
    end
end
