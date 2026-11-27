# frozen_string_literal: true

require "test_helper"

# A default category is stored under its English name and shown under its
# translation (Category#display_name). Lists that let people pick a category
# must use that label too, or the same category reads differently in a rule,
# a split and the category picker. Category::Group.select_options builds the
# usual [label, id] pairs; anything else takes display_name directly.
class CategoryLabelsTest < ActiveSupport::TestCase
  RAW_NAME_OPTIONS = [
    # family.categories.pluck(:name, :id), also with arguments in the chain
    /categor\w*(?:\.\w+(?:\([^()]*\))?)*\.pluck\(\s*:name\s*,\s*:id\b/,
    # collection_select over categories (:category_id, :parent_id,
    # :replacement_category_id, :target_id ...) labelled by :name, over
    # several lines too
    /collection_select\(?\s*:\w+,(?:(?!:id\b)[^%])*?categor(?:(?!:id\b)[^%])*?,\s*:id\s*,\s*:name\b/m,
    # options_from_collection_for_select(categories, :id, :name)
    /options_from_collection_for_select\(\s*@?\w*categor\w*[^,]*,\s*:id\s*,\s*:name\b/,
    # categories.map { |c| [c.name, c.id] } with any block variable
    /categor\w*(?:\.\w+(?:\([^()]*\))?)*\.map\s*\{\s*\|(\w+)\|\s*\[\s*\1\.name\s*,\s*\1\.id\s*\]/
  ].freeze

  test "category options are labelled by display_name" do
    offenders = Dir[Rails.root.join("app/**/*.{rb,erb}")].sort.flat_map do |file|
      path = Pathname(file).relative_path_from(Rails.root).to_s
      source = without_comments(File.read(file))
      RAW_NAME_OPTIONS.flat_map do |pattern|
        source.to_enum(:scan, pattern).map { "#{path}:#{source[0...Regexp.last_match.begin(0)].count("\n") + 1}" }
      end
    end

    assert_empty offenders.uniq, <<~MESSAGE
      Label category options with display_name (Category::Group.select_options
      for [label, id] pairs), so default categories show their translated name.
    MESSAGE
  end

  test "the guard recognizes the patterns it forbids" do
    samples = [
      "family.categories.alphabetically.pluck(:name, :id)",
      "family.categories.where(parent_id: nil).pluck(:name, :id)",
      "f.collection_select :parent_id, categories, :id, :name",
      "f.collection_select :target_id, @categories, :id, :name",
      "f.collection_select :replacement_category_id,\n  Current.family.categories.alphabetically,\n  :id, :name,\n  { prompt: true }",
      "options_from_collection_for_select(@categories, :id, :name)",
      "categories.map { |category| [category.name, category.id] }",
      "categories.map { |c| [ c.name, c.id ] }"
    ]

    samples.each do |sample|
      assert RAW_NAME_OPTIONS.any? { |pattern| sample.match?(pattern) }, sample
    end
  end

  test "the guard ignores ERB and Ruby comments" do
    source = without_comments("<%# collection_select :category_id, cats, :id, :name %>\n# categories.pluck(:name, :id)\n")

    assert RAW_NAME_OPTIONS.none? { |pattern| source.match?(pattern) }, source
  end

  private
    # Blank out comments but keep their line breaks, so line numbers stay right.
    def without_comments(source)
      source
        .gsub(/<%#.*?%>/m) { |comment| "\n" * comment.count("\n") }
        .gsub(/^[ \t]*#.*$/, "")
    end
end
