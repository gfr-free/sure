require "test_helper"

class CustomAccountSubtypesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    set_preview(true)
  end

  test "the page is preview only" do
    set_preview(false)

    get custom_account_subtypes_url

    assert_redirected_to root_path
  end

  test "lists the family's subtypes with their rules and account counts" do
    custom = @family.custom_account_subtypes.create!(accountable_type: "Depository", name: "Fixed 2y", rules: { "liquidity" => "locked" })
    accounts(:depository).update!(custom_account_subtype: custom)
    families(:empty).custom_account_subtypes.create!(accountable_type: "Depository", name: "Someone else's", rules: { "liquidity" => "locked" })

    get custom_account_subtypes_url

    assert_response :success
    assert_match "Fixed 2y", response.body
    assert_match I18n.t("accounts.liquidity.levels.locked"), response.body
    assert_match I18n.t("custom_account_subtypes.custom_account_subtype.accounts", count: 1), response.body
    assert_no_match "Someone else's", response.body
  end

  test "new starts from a built-in subtype's rules" do
    get new_custom_account_subtype_url(template: "Investment:401k")

    assert_response :success
    assert_select "input[name='custom_account_subtype[accountable_type]'][value='Investment']"
    assert_select "select[name='custom_account_subtype[liquidity]'] option[selected][value='long_term']"
    assert_select "select[name='custom_account_subtype[tax_treatment]'] option[selected][value='tax_deferred']"
  end

  test "new ignores an unknown template" do
    get new_custom_account_subtype_url(template: "Kernel:exit")

    assert_response :success
    assert_select "input[name='custom_account_subtype[accountable_type]'][value='Depository']"
  end

  test "creates a subtype" do
    assert_difference -> { @family.custom_account_subtypes.count }, 1 do
      post custom_account_subtypes_url, params: {
        custom_account_subtype: { accountable_type: "Depository", name: "Fixed 2y", liquidity: "locked", tax_treatment: "" }
      }
    end

    assert_redirected_to custom_account_subtypes_url
    assert_equal({ "liquidity" => "locked" }, @family.custom_account_subtypes.last.rules)
  end

  test "an invalid subtype renders the form again" do
    assert_no_difference -> { CustomAccountSubtype.count } do
      post custom_account_subtypes_url, params: {
        custom_account_subtype: { accountable_type: "Depository", name: "", liquidity: "locked" }
      }
    end

    assert_response :unprocessable_entity
  end

  test "updates the rules but not the account type" do
    custom = @family.custom_account_subtypes.create!(accountable_type: "Depository", name: "Fixed 2y", rules: { "liquidity" => "locked" })

    patch custom_account_subtype_url(custom), params: {
      custom_account_subtype: { name: "Fixed 3y", liquidity: "long_term", accountable_type: "Investment" }
    }

    assert_redirected_to custom_account_subtypes_url
    custom.reload
    assert_equal "Fixed 3y", custom.name
    assert_equal "long_term", custom.liquidity
    assert_equal "Depository", custom.accountable_type
  end

  test "deletes a subtype" do
    custom = @family.custom_account_subtypes.create!(accountable_type: "Depository", name: "Fixed 2y", rules: { "liquidity" => "locked" })

    assert_difference -> { CustomAccountSubtype.count }, -1 do
      delete custom_account_subtype_url(custom)
    end

    assert_redirected_to custom_account_subtypes_url
  end

  test "another family's subtype cannot be changed" do
    foreign = families(:empty).custom_account_subtypes.create!(accountable_type: "Depository", name: "Foreign", rules: { "liquidity" => "locked" })

    patch custom_account_subtype_url(foreign), params: { custom_account_subtype: { name: "Mine now" } }
    assert_response :not_found

    delete custom_account_subtype_url(foreign)
    assert_response :not_found
    assert_equal "Foreign", foreign.reload.name
  end

  test "guests can look but not change" do
    guest = users(:family_member)
    guest.update!(role: "guest", preferences: (guest.preferences || {}).merge("preview_features_enabled" => true))
    sign_in guest

    get custom_account_subtypes_url
    assert_response :success

    assert_no_difference -> { CustomAccountSubtype.count } do
      post custom_account_subtypes_url, params: {
        custom_account_subtype: { accountable_type: "Depository", name: "Fixed 2y", liquidity: "locked" }
      }
    end
    assert_redirected_to custom_account_subtypes_url
  end

  private
    def set_preview(enabled)
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => enabled))
    end
end
