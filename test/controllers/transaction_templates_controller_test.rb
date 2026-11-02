require "test_helper"

class TransactionTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @template = @family.transaction_templates.create!(
      name: "Rent", nature: "outflow", amount: 950, currency: "USD",
      account: accounts(:depository), category: categories(:food_and_drink)
    )
  end

  test "lists the family's templates" do
    get transaction_templates_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@template)}", text: /Rent/
  end

  test "renders the new form" do
    get new_transaction_template_url

    assert_response :success
    assert_select "input[name='transaction_template[name]']"
  end

  test "creates a template without an amount" do
    assert_difference -> { @family.transaction_templates.count } do
      post transaction_templates_url, params: {
        transaction_template: {
          name: "Groceries", nature: "outflow", amount: "", currency: "USD",
          account_id: accounts(:depository).id, category_id: categories(:food_and_drink).id,
          merchant_id: merchants(:amazon).id, tag_ids: [ tags(:one).id ], notes: "Weekly"
        }
      }
    end

    assert_redirected_to transaction_templates_url
    template = @family.transaction_templates.find_by!(name: "Groceries")
    assert_nil template.amount
    assert_equal merchants(:amazon), template.merchant
    assert_equal [ tags(:one) ], template.tags.to_a
  end

  test "drops references from another family" do
    other_family = families(:empty)
    other_category = other_family.categories.create!(name: "Foreign", color: "#000000")
    other_tag = other_family.tags.create!(name: "Foreign tag")
    other_account = other_family.accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)

    post transaction_templates_url, params: {
      transaction_template: {
        name: "Sneaky", nature: "outflow", account_id: other_account.id,
        category_id: other_category.id, tag_ids: [ other_tag.id ]
      }
    }

    template = @family.transaction_templates.find_by!(name: "Sneaky")
    assert_nil template.account_id
    assert_nil template.category_id
    assert_empty template.tags
  end

  test "re-renders the form when invalid" do
    assert_no_difference -> { TransactionTemplate.count } do
      post transaction_templates_url, params: { transaction_template: { name: "", nature: "outflow" } }
    end

    assert_response :unprocessable_entity
  end

  test "updates a template" do
    patch transaction_template_url(@template), params: { transaction_template: { name: "Rent flat", amount: "1000" } }

    assert_redirected_to transaction_templates_url
    assert_equal "Rent flat", @template.reload.name
    assert_equal 1000, @template.amount
  end

  test "a member keeps an account that is not shared with them" do
    @template.update!(account: accounts(:other_asset))
    sign_in users(:family_member)

    get edit_transaction_template_url(@template)
    assert_response :success
    assert_select "select[name='transaction_template[account_id]']", count: 0

    patch transaction_template_url(@template), params: {
      transaction_template: { name: "Rent", account_id: accounts(:depository).id }
    }

    assert_equal accounts(:other_asset), @template.reload.account
  end

  test "the list hides an account that is not shared with the viewer" do
    @template.update!(account: accounts(:other_asset))
    sign_in users(:family_member)

    get transaction_templates_url

    assert_response :success
    assert_no_match accounts(:other_asset).name, response.body
  end

  test "deletes a template" do
    assert_difference -> { TransactionTemplate.count }, -1 do
      delete transaction_template_url(@template)
    end

    assert_redirected_to transaction_templates_url
  end

  test "templates of another family are not found" do
    other_template = families(:empty).transaction_templates.create!(name: "Foreign")

    patch transaction_template_url(other_template), params: { transaction_template: { name: "Taken" } }
    assert_response :not_found

    delete transaction_template_url(other_template)
    assert_response :not_found
    assert TransactionTemplate.exists?(other_template.id)
  end

  test "guests cannot manage templates" do
    sign_in users(:intro_user)

    get transaction_templates_url

    assert_redirected_to accounts_url
  end
end
