require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "create falls back to the stored return_to when no form param is present" do
    get new_account_path(return_to: transactions_path) # StoreLocation captures it into the session

    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: { name: "Return To Checking", currency: "USD", balance: 100, accountable_type: "Depository" }
      }
    end

    assert_redirected_to transactions_path
  end

  test "create prefers the form return_to over the session value" do
    get new_account_path(return_to: transactions_path) # session return_to

    post depositories_path, params: {
      account: { name: "Form RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: budgets_path }
    }

    assert_redirected_to budgets_path
  end

  test "create ignores an external return_to (open-redirect guard)" do
    post depositories_path, params: {
      account: { name: "Evil RT Checking", currency: "USD", balance: 100, accountable_type: "Depository", return_to: "https://evil.example/phish" }
    }

    created = Account.order(:created_at).last
    assert_redirected_to account_path(created) # not the external URL
  end

  test "update persists enable_category_matcher through the shared update action" do
    linked_account = accounts(:connected)
    assert linked_account.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "0" }
    }

    refute linked_account.reload.enable_category_matcher?

    patch depository_path(linked_account), params: {
      account: { enable_category_matcher: "1" }
    }

    assert linked_account.reload.enable_category_matcher?
  end

  test "edit form renders category matcher toggle only for accounts that support it" do
    get edit_account_url(accounts(:connected))
    assert_response :success
    assert_select "input[type=checkbox][name='account[enable_category_matcher]']", 1

    get edit_account_url(accounts(:depository))
    assert_response :success
    assert_select "input[name='account[enable_category_matcher]']", 0
  end

  # --- availability (Account::Liquidity) ------------------------------------

  test "create takes the subtype default without treating it as a manual choice" do
    post depositories_path, params: {
      account: { name: "Term deposit", currency: "USD", balance: 100, subtype: "cd", accountable_type: "Depository" }
    }

    account = Account.order(:created_at).last
    assert_equal "locked", account.liquidity
    assert_not account.liquidity_manual?
  end

  test "update stores a manual availability with its release date" do
    patch depository_path(@account), params: {
      account: { liquidity_choice: "locked", available_on: "2030-03-31", notice_period_days: "30" }
    }

    @account.reload
    assert_equal "locked", @account.liquidity
    assert @account.liquidity_manual?
    assert_equal Date.new(2030, 3, 31), @account.available_on
    assert_equal 30, @account.notice_period_days
  end

  test "update can hand availability back to the subtype" do
    @account.update!(liquidity_choice: "long_term")

    patch depository_path(@account), params: { account: { liquidity_choice: "automatic" } }

    assert_equal "immediate", @account.reload.liquidity
    assert_not @account.liquidity_manual?
  end

  test "the availability fields are preview only" do
    set_preview(false)
    get edit_account_url(@account)
    assert_select "select[name='account[liquidity_choice]']", 0

    set_preview(true)
    get edit_account_url(@account)
    assert_select "select[name='account[liquidity_choice]']", 1
    assert_select "input[name='account[available_on]']", 1
  end

  test "update writes the interest terms from the form" do
    patch depository_path(@account), params: {
      account: {
        interest_rate_input: "3.5", overdraft_rate_input: "11.9", interest_payout_frequency: "quarterly",
        planned_interest_rate: "1.5", planned_interest_rate_on: 2.months.from_now.to_date.iso8601
      }
    }

    @account.reload
    assert_equal "quarterly", @account.interest_payout_frequency
    assert_equal BigDecimal("3.5"), @account.interest_rate_on(Date.current)
    assert_equal BigDecimal("11.9"), @account.interest_rate_on(Date.current, applies_to: "debit")
    assert_equal [ BigDecimal("1.5") ], @account.upcoming_interest_rates.map(&:rate)
  end

  test "a planned rate change in the past comes back as a form error" do
    patch depository_path(@account), params: {
      account: { planned_interest_rate: "1.5", planned_interest_rate_on: Date.current.iso8601 }
    }

    assert_response :unprocessable_entity
    assert_empty @account.interest_rates.reload
  end

  test "the interest fields are preview only" do
    set_preview(false)
    get edit_account_url(@account)
    assert_select "input[name='account[interest_rate_input]']", 0

    set_preview(true)
    get edit_account_url(@account)
    assert_select "input[name='account[interest_rate_input]']", 1
    assert_select "input[name='account[overdraft_rate_input]']", 1
    assert_select "select[name='account[interest_payout_frequency]']", 1
  end

  test "update writes the tax settings, the treatment onto the bank account" do
    patch depository_path(@account), params: {
      account: {
        tax_treatment_choice: "tax_exempt", tax_withheld_choice: "no",
        tax_allowance_allocation: "801", january_tax_debit: "12.5"
      }
    }

    @account.reload
    assert_equal :tax_exempt, @account.tax_treatment
    assert_equal false, @account.tax_withheld_at_source
    assert_equal BigDecimal("801"), @account.tax_allowance_allocation
    assert_equal BigDecimal("12.5"), @account.january_tax_debit

    patch depository_path(@account), params: { account: { tax_treatment_choice: "", tax_withheld_choice: "profile" } }

    @account.reload
    assert_nil @account.accountable[:tax_treatment]
    assert_nil @account.tax_withheld_at_source
  end

  test "the tax fields are preview only" do
    set_preview(false)
    get edit_account_url(@account)
    assert_select "[data-testid='account-tax-fields']", 0

    set_preview(true)
    get edit_account_url(@account)
    assert_select "select[name='account[tax_treatment_choice]']", 1
    assert_select "select[name='account[tax_withheld_choice]']", 1
    assert_select "input[name='account[tax_allowance_allocation]']", 1
    assert_select "input[name='account[january_tax_debit]']", 1
  end

  test "the interest tab shows the tax on the next payment" do
    set_preview(true)
    @user.tax_profiles.create!(valid_from_year: Date.current.year, currency: "USD", rate_interest: 25, annual_allowance: 0)
    @account.update!(owner: @user, interest_payout_frequency: "monthly", tax_withheld_at_source: false)
    @account.interest_rates.create!(effective_from: 1.year.ago.to_date, rate: 3.5)

    get account_url(@account, tab: "interest")

    assert_response :success
    assert_match I18n.t("accounts.interest.tax_due_later", amount: "").strip, response.body
  end

  test "the account page shows availability and the details tab only with preview" do
    @account.update!(subtype: "cd", available_on: Date.new(2030, 3, 31))

    set_preview(false)
    get account_url(@account)
    assert_response :success
    assert_select "[data-testid='account-rule-details']", 0
    assert_no_match I18n.t("accounts.liquidity.badge.locked_until", date: I18n.l(Date.new(2030, 3, 31), format: :long)), response.body

    set_preview(true)
    get account_url(@account, tab: "details")
    assert_response :success
    assert_select "[data-testid='account-rule-details']", 1
    assert_match I18n.t("accounts.liquidity.badge.locked_until", date: I18n.l(Date.new(2030, 3, 31), format: :long)), response.body
    assert_match I18n.t("accounts.liquidity.details.sources.subtype", subtype: @account.long_subtype_label), response.body
  end

  # --- member-owned connections (issue #3579) ------------------------------

  test "a member sees only member-connectable providers in the method selector" do
    Provider::Registry.stubs(:plaid_provider_for_region).returns(stub("plaid"))
    Family.any_instance.stubs(:can_connect_plaid_us?).returns(true)
    Family.any_instance.stubs(:can_connect_plaid_eu?).returns(false)

    sign_in users(:family_member)
    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_plaid_item_path(region: "us", accountable_type: "Depository"), count: 1
    # SimpleFIN is tenant-wide, so it must not be offered to a member even
    # when it is configured.
    assert_select "a[href*=?]", "simplefin", count: 0
  end

  test "an admin still sees every configured provider in the method selector" do
    Provider::Registry.stubs(:plaid_provider_for_region).returns(stub("plaid"))
    Family.any_instance.stubs(:can_connect_plaid_us?).returns(true)
    Family.any_instance.stubs(:can_connect_plaid_eu?).returns(false)

    sign_in users(:family_admin)
    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_plaid_item_path(region: "us", accountable_type: "Depository"), count: 1
  end

  test "a member is offered manual entry even with no connectable providers" do
    Family.any_instance.stubs(:can_connect_plaid_us?).returns(false)
    Family.any_instance.stubs(:can_connect_plaid_eu?).returns(false)

    sign_in users(:family_member)
    get new_depository_path(step: "method_select")

    assert_response :success
    assert_select "a[href=?]", new_depository_path, count: 1
  end

  private
    def set_preview(enabled)
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => enabled))
    end
end
