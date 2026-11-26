require "test_helper"

# Every category picker with a search box finds a category by the same rule
# (utils/search_match), so every row must carry the attributes from
# CategoriesHelper#category_search_data. This renders each picker and checks
# its rows, and scans the views so a new picker cannot set a category's
# search name by hand.
class CategoryPickersSearchTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    # Bills and report trends sit behind the preview gate.
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @entry = create_transaction(account: accounts(:depository), name: "Picker coverage", amount: 20)
  end

  test "transaction list category menu" do
    get category_dropdown_url(transaction_id: @entry.entryable.id)

    assert_category_rows "[data-list-filter-target='list'] .filterable-item"
  end

  test "transaction filter menu" do
    get filters_transactions_url, headers: { "Turbo-Frame" => "transaction-filters" }

    assert_category_rows "[data-controller~='category-filter'] .filterable-item"
  end

  test "quick categorize page" do
    get transactions_categorize_url

    assert_category_rows "[data-categorize-target='list'] .filterable-item"
  end

  test "category select in the transaction drawer, the new transaction form and the bill form" do
    [
      transaction_url(@entry),
      new_transaction_url,
      edit_recurring_transaction_url(recurring_transactions(:netflix_subscription))
    ].each do |url|
      get url, headers: { "Turbo-Frame" => url == transaction_url(@entry) ? "drawer" : "modal" }

      assert_category_rows "[data-category-select-target='option']", context: url
    end
  end

  test "searchable category select in bulk edit, split and transfer" do
    get new_transactions_bulk_update_url, params: {
      has_transaction_entry: "true",
      has_transfer_entry: "false",
      has_category_editable_entry: "true",
      has_normal_transaction_entry: "true"
    }
    assert_category_rows category_ds_select_rows("bulk_update[category_id]"), context: "bulk edit"

    get new_transaction_split_path(@entry)
    assert_category_rows ".category-select-container .filterable-item", context: "split"

    # A loan payment keeps its category; a plain transfer shows no picker.
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:loan), amount: 100)
    assert transfer.categorizable?
    get transfer_url(transfer)
    assert_category_rows category_ds_select_rows("transfer[category_id]"), context: "transfer"
  end

  test "dashboard spending trend, reports trends and classifier popovers" do
    create_transaction(account: accounts(:depository), name: "Trend spend", amount: 30,
                       category: categories(:food_and_drink), date: Date.current)

    get root_path
    assert_category_rows "[data-controller~='category-filter'] .filterable-item", context: "dashboard"

    get reports_path(period_type: :custom, start_date: 1.month.ago.beginning_of_month.to_date, end_date: Date.current.end_of_month)
    assert_category_rows "[data-controller~='category-filter'] .filterable-item", context: "reports"

    get settings_classifier_path
    assert_category_rows "[data-controller~='category-filter'] .filterable-item", context: "classifier"
  end

  # Checking a parent in a cascading list checks all its subcategories, so a
  # search there must show whole groups (list-filter wholeGroups), never a
  # parent without its hidden siblings.
  test "every cascading category list searches whole groups" do
    create_transaction(account: accounts(:depository), name: "Trend spend", amount: 30,
                       category: categories(:food_and_drink), date: Date.current)

    {
      "transaction filter" => -> { get filters_transactions_url, headers: { "Turbo-Frame" => "transaction-filters" } },
      "dashboard" => -> { get root_path },
      "reports" => -> { get reports_path(period_type: :custom, start_date: 1.month.ago.beginning_of_month.to_date, end_date: Date.current.end_of_month) },
      "classifier" => -> { get settings_classifier_path }
    }.each do |context, request|
      request.call
      assert_response :success, context

      lists = css_select("[data-controller~='category-filter']")
      assert_operator lists.size, :>, 0, "no cascading list (#{context})"
      lists.each do |list|
        assert_equal "true", list["data-list-filter-whole-groups-value"], "whole groups (#{context})"
      end
    end
  end

  # The pages above are the ones rendered today; a new cascading list must
  # set wholeGroups too. Every view that starts a category-filter controller
  # must also set the value (directly or through _filter_popover, which
  # derives it from its list_controllers).
  test "no view starts a category-filter list without whole groups" do
    offenders = Dir[Rails.root.join("app/{views,components}/**/*.erb")].filter_map do |path|
      source = File.read(path)
      next unless source.match?(/data-controller="[^"]*\bcategory-filter\b/)
      next if source.include?("data-list-filter-whole-groups-value")

      Pathname(path).relative_path_from(Rails.root).to_s
    end

    assert_empty offenders, "set data-list-filter-whole-groups-value on cascading category lists"
  end

  # A category row whose search name is written by hand drifts from the
  # others; it must come from category_search_data instead. Any line that
  # sets a filter name and mentions a category (in any spelling) counts.
  test "no view sets a category's search name by hand" do
    offenders = Dir[Rails.root.join("app/{views,components}/**/*.{erb,rb}")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.match?(/data-filter-name=|filter_name:/)
        next unless line.match?(/categor|\bcat\b/i)

        "#{Pathname(path).relative_path_from(Rails.root)}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty offenders, "use category_search_data for category picker rows"
  end

  private

    def category_ds_select_rows(field_name)
      root = css_select("[data-controller~='select'][data-controller~='list-filter']").find do |select|
        select.at_css("input[name='#{field_name}']")
      end
      assert root, "no searchable select for #{field_name}"
      root.css(".filterable-item")
    end

    # Every row must carry the shared attributes; only a select's blank
    # choice (empty value or category id) has none. Rows of real categories must match them.
    def assert_category_rows(rows_or_selector, context: nil)
      assert_response :success, context
      rows = rows_or_selector.is_a?(String) ? css_select(rows_or_selector) : rows_or_selector
      rows = rows.reject do |row|
        %w[data-value data-category-id].any? { |attr| row.key?(attr) && row[attr].blank? }
      end

      assert_operator rows.size, :>, 0, "no category rows found (#{context})"

      ids = rows.map { |row| row["data-filter-id"] }.compact
      categories = @family.categories.where(id: ids).index_by(&:id)

      rows.each do |row|
        assert row["data-filter-name"].present?, "row has a label (#{context}): #{row.to_html.truncate(200)}"
        terms = JSON.parse(row["data-filter-terms"].to_s) rescue nil
        assert_kind_of Array, terms, "row carries category_search_data (#{context}): #{row.to_html.truncate(200)}"

        # The synthetic "Uncategorized" row has no id; it is still searchable.
        next if row["data-filter-id"].blank?

        category = categories.fetch(row["data-filter-id"])
        assert_equal category.name, terms.first, "stored name first (#{context})"
        assert_includes terms, category.display_name, "shown name searchable (#{context})"
        assert_equal category.parent_id.to_s, row["data-filter-parent-id"].to_s, "parent id (#{context})"
      end
    end
end
