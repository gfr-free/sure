require "test_helper"

class Transactions::SearchFiltersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "renders the filter menu inside its frame with the form's field names" do
    get transactions_search_filters_url

    assert_response :success
    assert_select "turbo-frame#transaction-filters" do
      assert_select "#transaction-filters-menu"
      assert_select "input[name='q[accounts][]'][value=?]", accounts(:depository).name
      assert_select "input[name='q[categories][]'][value=?]", categories(:food_and_drink).name
      assert_select "input[name='q[merchants][]'][value=?]", merchants(:amazon).name
      assert_select "input#q_start_date[name='q[start_date]']"
      assert_select "input#q_amount[name='q[amount]']"
      assert_select "form", count: 0
    end
  end

  test "marks the active filters as checked and offers to clear them" do
    get transactions_search_filters_url(q: { categories: [ categories(:food_and_drink).name ], start_date: "2024-01-01" })

    assert_response :success
    assert_select "input[name='q[categories][]'][value=?][checked]", categories(:food_and_drink).name
    assert_select "input[name='q[categories][]'][value=?]:not([checked])", categories(:income).name
    assert_select "input#q_start_date[value='2024-01-01']"
    assert_select "a[href=?][data-turbo-frame='_top']", transactions_path(clear_filters: true)
  end

  test "hides the clear link when no filter is active" do
    get transactions_search_filters_url

    assert_response :success
    assert_select "a[href=?]", transactions_path(clear_filters: true), count: 0
  end

  test "requires a signed in user" do
    @user.sessions.destroy_all
    get transactions_search_filters_url

    assert_redirected_to new_session_url
  end
end
