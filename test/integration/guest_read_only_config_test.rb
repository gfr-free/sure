require "test_helper"

class GuestReadOnlyConfigTest < ActionDispatch::IntegrationTest
  setup do
    sign_in family_guest
  end

  test "guest can view family configuration" do
    [ categories_path, tags_path, rules_path, family_merchants_path ].each do |path|
      get path

      assert_response :success, "#{path} should stay readable for guests"
    end
  end

  test "guest cannot create categories, tags or merchants" do
    assert_no_difference([ "Category.count", "Tag.count", "FamilyMerchant.count" ]) do
      post categories_path, params: { category: { name: "Guest category", color: "#000000" } }
      post tags_path, params: { tag: { name: "Guest tag" } }
      post family_merchants_path, params: { family_merchant: { name: "Guest merchant" } }
    end
  end

  test "guest cannot update or delete existing configuration" do
    category = categories(:food_and_drink)
    tag = tags(:one)
    merchant = merchants(:netflix)

    patch category_path(category), params: { category: { name: "Renamed by guest" } }
    patch tag_path(tag), params: { tag: { name: "Renamed by guest" } }
    patch family_merchant_path(merchant), params: { family_merchant: { name: "Renamed by guest" } }

    assert_not_equal "Renamed by guest", category.reload.name
    assert_not_equal "Renamed by guest", tag.reload.name
    assert_not_equal "Renamed by guest", merchant.reload.name

    assert_no_difference([ "Category.count", "Tag.count", "FamilyMerchant.count", "Rule.count" ]) do
      delete category_path(category)
      delete tag_path(tag)
      delete family_merchant_path(merchant)
      delete destroy_all_categories_path
      delete destroy_all_tags_path
      delete destroy_all_rules_path
      post category_deletions_path(category)
      post tag_deletions_path(tag)
    end
  end

  test "guest cannot apply rules to family transactions" do
    Rule.any_instance.expects(:apply_later).never

    post apply_rule_path(rules(:one))
    post apply_all_rules_path

    assert_redirected_to root_path
    assert_equal I18n.t("shared.require_non_guest"), flash[:alert]
  end

  test "members can still manage family configuration" do
    sign_in users(:family_member)

    assert_difference("Tag.count", 1) do
      post tags_path, params: { tag: { name: "Member tag" } }
    end
  end
end
