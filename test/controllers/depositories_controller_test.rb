require "test_helper"

class DepositoriesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "saves the custom group and shows it in the edit form for preview users" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))

    patch depository_path(@account), params: { account: { custom_group: "  Vacation " } }

    assert_equal "Vacation", @account.reload.custom_group

    get edit_depository_path(@account)
    assert_select "input[name='account[custom_group]'][value='Vacation']"
    assert_select "datalist#account_custom_group_suggestions option[value='Vacation']"
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

  test "create persists a manually entered iban" do
    post depositories_path, params: {
      account: { name: "IBAN Checking", currency: "USD", balance: 100, accountable_type: "Depository", iban: "de89 3704 0044 0532 0130 00" }
    }

    created = Account.order(:created_at).last
    assert_equal "DE89370400440532013000", created.iban # pipelock:ignore IBAN
  end

  test "create does not choke on a stray remove_iban param" do
    assert_difference -> { Account.count } => 1 do
      post depositories_path, params: {
        account: { name: "No Iban Checking", currency: "USD", balance: 100, accountable_type: "Depository", remove_iban: "1" }
      }
    end

    created = Account.order(:created_at).last
    assert_nil created.iban
  end

  test "create re-renders the form instead of a 500 when the iban is already used in the family" do
    @account.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN

    assert_no_difference -> { Account.count } do
      post depositories_path, params: {
        account: { name: "Duplicate IBAN Checking", currency: "USD", balance: 100, accountable_type: "Depository", iban: "DE89370400440532013000" } # pipelock:ignore IBAN
      }
    end

    assert_response :unprocessable_entity
  end

  test "create re-renders the form instead of a 500 on a raw unique-index race" do
    # Simulates two concurrent requests both passing the Rails uniqueness
    # validation before either commits -- the second one hits the raw DB
    # constraint instead, surfacing as RecordNotUnique rather than the
    # RecordInvalid the previous test covers.
    Account.any_instance.stubs(:save!).raises(
      ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint")
    )

    assert_no_difference -> { Account.count } do
      post depositories_path, params: {
        account: { name: "Race Checking", currency: "USD", balance: 100, accountable_type: "Depository", iban: "DE89370400440532013000" } # pipelock:ignore IBAN
      }
    end

    assert_response :unprocessable_entity
  end

  test "update re-renders the form instead of a 500 on a raw unique-index race" do
    linked_account = accounts(:connected)
    Account.any_instance.stubs(:update).raises(
      ActiveRecord::RecordNotUnique.new("duplicate key value violates unique constraint")
    )

    patch depository_path(linked_account), params: {
      account: { iban: "DE89370400440532013000" } # pipelock:ignore IBAN
    }

    assert_response :unprocessable_entity
  end

  test "update rolls back a balance change when the iban update fails in the same request" do
    linked_account = accounts(:connected)
    other_account = accounts(:depository)
    other_account.update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN
    original_balance = linked_account.balance

    patch depository_path(linked_account), params: {
      account: { balance: original_balance + 100, iban: "DE89370400440532013000" } # pipelock:ignore IBAN
    }

    assert_response :unprocessable_entity
    assert_equal original_balance, linked_account.reload.balance,
      "the balance change must not persist when the same request's iban update fails"
  end

  test "update persists a manually entered iban through the shared update action" do
    linked_account = accounts(:connected)

    patch depository_path(linked_account), params: {
      account: { iban: "AT611904300234573201" } # pipelock:ignore IBAN
    }

    assert_equal "AT611904300234573201", linked_account.reload.iban # pipelock:ignore IBAN
  end

  test "update with a blank iban field leaves the stored iban unchanged" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    patch depository_path(linked_account), params: {
      account: { name: "Renamed", iban: "" }
    }

    assert_equal "AT611904300234573201", linked_account.reload.iban # pipelock:ignore IBAN
    assert_equal "Renamed", linked_account.reload.name
  end

  test "update with remove_iban checked clears the stored iban even with a blank field" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    patch depository_path(linked_account), params: {
      account: { iban: "", remove_iban: "1" }
    }

    assert_nil linked_account.reload.iban
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

  test "edit form never renders the stored iban" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    get edit_account_url(linked_account)

    assert_response :success
    refute_includes response.body, "AT611904300234573201" # pipelock:ignore IBAN
    assert_select "input[type=checkbox][name='account[remove_iban]']", 1
  end

  test "iban field masks keystrokes like a password field and signals a stored value" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN

    get edit_account_url(linked_account)

    assert_response :success
    # type=password, not type=text: typed input must be masked as you go,
    # not just withheld from the initial render.
    assert_select "input[type=password][name='account[iban]']", 1
    # The placeholder alone ("IBAN on file...") was easy to miss -- a fixed
    # run of bullets makes a stored value visually obvious at a glance.
    assert_select "input[name='account[iban]'][placeholder^=?]", "••••"
  end

  test "edit form does not render a remove_iban toggle when no iban is stored" do
    linked_account = accounts(:connected)
    linked_account.update!(iban: nil)

    get edit_account_url(linked_account)

    assert_response :success
    assert_select "input[type=checkbox][name='account[remove_iban]']", 0
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
      account: { liquidity_choice: "locked", available_on: "2030-03-31" }
    }

    @account.reload
    assert_equal "locked", @account.liquidity
    assert @account.liquidity_manual?
    assert_equal Date.new(2030, 3, 31), @account.available_on
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
