# frozen_string_literal: true

require "test_helper"

# A default category is stored under its English name and shown under its
# translation (Category#display_name). Lists that let people pick a category
# must use that label too, or the same category reads differently in a rule,
# a split and the category picker. Category::Group.select_options builds the
# usual [label, id] pairs; anything else takes display_name directly.
class CategoryLabelsTest < ActiveSupport::TestCase
  RAW_NAME_OPTIONS = [
    # family.categories.pluck(:name, :id) and the like
    /categor\w*(?:\.\w+)*\.pluck\(\s*:name\s*,\s*:id\b/,
    # collection_select :category_id / :parent_id labelled by :name
    /collection_select\(?\s*:(?:category|parent)_id\b[^\n]*:name\b/,
    # [category.name, category.id] built by hand
    /\[\s*\w*categor\w*\.name\s*,\s*\w*categor\w*\.id\s*\]/
  ].freeze

  test "category options are labelled by display_name" do
    offenders = Dir[Rails.root.join("app/**/*.{rb,erb}")].sort.flat_map do |file|
      path = Pathname(file).relative_path_from(Rails.root).to_s
      File.readlines(file).each_with_index.filter_map do |line, index|
        "#{path}:#{index + 1}" if RAW_NAME_OPTIONS.any? { |pattern| line.match?(pattern) }
      end
    end

    assert_empty offenders, <<~MESSAGE
      Label category options with display_name (Category::Group.select_options
      for [label, id] pairs), so default categories show their translated name.
    MESSAGE
  end

  test "the guard recognizes the patterns it forbids" do
    samples = [
      "family.categories.alphabetically.pluck(:name, :id)",
      "f.collection_select :parent_id, categories, :id, :name",
      "categories.map { |category| [category.name, category.id] }"
    ]

    samples.each do |sample|
      assert RAW_NAME_OPTIONS.any? { |pattern| sample.match?(pattern) }, sample
    end
  end
end
