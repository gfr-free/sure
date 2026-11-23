require "test_helper"

class ReviewsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  include SqlQueryCapture

  MARKER = "Reviewpagemarker".freeze

  setup do
    @user = users(:family_admin)
    @family = @user.family
    enable_preview(@user)
    sign_in @user
    ensure_tailwind_build
  end

  test "redirects users without preview access to the dashboard" do
    disable_preview(@user)

    get review_path

    assert_redirected_to root_path
    assert_equal I18n.t("preview.not_enabled"), flash[:alert]
  end

  test "shows a tile with a count for every review kind" do
    create_transaction(name: "#{MARKER} one", category: nil, merchant: nil)

    get review_path(q: { search: MARKER })

    assert_response :success
    Transaction::ReviewQueue::KINDS.each do |kind|
      assert_select "#review-kind-#{kind}", 1
    end
    assert_select "#review-kind-uncategorized", text: /1/
    assert_select "#review-kind-uncategorized[aria-current=page]"
  end

  test "lists only the transactions of the chosen kind" do
    no_merchant = create_transaction(name: "#{MARKER} merchantless", category: categories(:food_and_drink), merchant: nil)
    uncategorized = create_transaction(name: "#{MARKER} categoryless", category: nil, merchant: merchants(:netflix))

    get review_path(kind: "no_merchant", q: { search: MARKER })

    assert_response :success
    assert_select "#review-kind-no_merchant[aria-current=page]"
    assert_select "##{ActionView::RecordIdentifier.dom_id(no_merchant)}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(uncategorized)}", count: 0
  end

  test "an unknown kind falls back to the first kind with work" do
    create_transaction(name: "#{MARKER} merchantless", category: categories(:food_and_drink), merchant: nil)

    get review_path(kind: "everything", q: { search: MARKER })

    assert_response :success
    assert_select "#review-kind-no_merchant[aria-current=page]"
  end

  test "shows an empty state when nothing in the kind matches" do
    get review_path(kind: "possible_duplicate", q: { search: MARKER })

    assert_response :success
    assert_select "h1", text: I18n.t("reviews.show.title")
    assert_select "p", text: I18n.t("reviews.show.empty.title")
  end

  test "filters narrow the counts and show as removable badges" do
    create_transaction(name: "#{MARKER} checking", category: nil, merchant: nil)
    create_transaction(name: "#{MARKER} card", category: nil, merchant: nil, account: accounts(:credit_card))

    get review_path(q: { search: MARKER, accounts: [ accounts(:credit_card).name ] })

    assert_response :success
    assert_select "#review-kind-uncategorized", text: /1/
    assert_select "#review-filters li", minimum: 2
  end

  test "clearing a filter keeps the review page and the chosen kind" do
    delete clear_filter_review_path(param_key: "search", param_value: MARKER, kind: "no_merchant", q: { search: MARKER, types: [ "expense" ] })

    assert_redirected_to review_path(q: { types: [ "expense" ] }, kind: "no_merchant")
  end

  test "the nav shows the review entry only with preview access" do
    get transactions_path
    assert_select "a[href='#{review_path}']", minimum: 1

    disable_preview(@user)
    get transactions_path
    assert_select "a[href='#{review_path}']", count: 0
  end

  test "the nav badge counts what the viewer can still categorize" do
    expected = Current.set(session: @user.sessions.first || @user.sessions.create!) do
      @user.family.entries.joins(:account).merge(Account.annotatable_by(@user)).uncategorized_transactions.count
    end

    get transactions_path

    assert_select "a[href='#{review_path}'] span", text: (expected > 9 ? "9+" : expected.to_s)
  end

  test "renders a page of rows without a query per row" do
    5.times { |i| create_transaction(name: "#{MARKER} row #{i}", category: nil, merchant: merchants(:netflix)) }
    get transactions_path # warm the layout's caches so both measured requests start equal
    baseline = capture_sql_queries { get review_path(q: { search: MARKER }) }.size

    5.times { |i| create_transaction(name: "#{MARKER} more #{i}", category: nil, merchant: merchants(:netflix)) }
    get transactions_path
    grown = capture_sql_queries { get review_path(q: { search: MARKER }) }.size

    assert_response :success
    assert_select "#review-kind-uncategorized", text: /10/
    assert_operator grown, :<=, baseline, "query count grew with the number of rows (#{baseline} -> #{grown})"
  end

  private
    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => false))
    end
end
