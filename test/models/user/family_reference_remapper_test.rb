require "test_helper"

class User::FamilyReferenceRemapperTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_member)
    @old_family = @user.family
    @new_family = Family.create!(name: "Target Family", currency: "USD")
    @account = Account.create!(family: @old_family, owner: @user, name: "Moving Checking",
                               balance: 100, currency: "USD", accountable: Depository.new)
  end

  test "transfer_to_family! copies categories, merchants and tags the new family lacks" do
    entry = create_transaction(account: @account, category: categories(:subcategory),
                               merchant: merchants(:netflix), tags: [ tags(:one) ])

    assert_no_difference -> { @old_family.categories.count } do
      @user.transfer_to_family!(@new_family, role: "admin")
    end

    transaction = entry.reload.entryable
    category = transaction.category

    assert_equal @new_family, category.family
    assert_equal "Restaurants", category.name
    assert_equal @new_family, category.parent.family
    assert_equal "Food & Drink", category.parent.name

    assert_equal @new_family, transaction.merchant.family
    assert_equal "Netflix", transaction.merchant.name
    assert_equal "#fd7f6f", transaction.merchant.color

    assert_equal [ [ @new_family.id, "Trips" ] ], transaction.tags.map { |tag| [ tag.family_id, tag.name ] }

    assert_equal @old_family, categories(:subcategory).reload.family
    assert_equal @old_family, merchants(:netflix).reload.family
    assert_equal @old_family, tags(:one).reload.family
  end

  test "transfer_to_family! reuses same-named records in the new family" do
    existing_category = @new_family.categories.create!(name: "Food & Drink", color: "#4da568", lucide_icon: "utensils")
    existing_merchant = @new_family.merchants.create!(name: "Netflix", color: "#6471eb")
    existing_tag = @new_family.tags.create!(name: "Trips", color: "#e99537")
    entry = create_transaction(account: @account, category: categories(:food_and_drink),
                               merchant: merchants(:netflix), tags: [ tags(:one) ])

    assert_no_difference [ -> { @new_family.categories.count }, -> { @new_family.merchants.count }, -> { @new_family.tags.count } ] do
      @user.transfer_to_family!(@new_family, role: "admin")
    end

    transaction = entry.reload.entryable
    assert_equal existing_category, transaction.category
    assert_equal existing_merchant, transaction.merchant
    assert_equal [ existing_tag ], transaction.tags.to_a
  end

  test "transfer_to_family! keeps one tagging when a transaction already has the target tag" do
    existing_tag = @new_family.tags.create!(name: "Trips", color: "#e99537")
    entry = create_transaction(account: @account)
    entry.entryable.taggings.create!(tag: tags(:one))
    entry.entryable.taggings.create!(tag: existing_tag)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_equal [ existing_tag ], entry.reload.entryable.tags.to_a
  end

  test "transfer_to_family! nests a copied subcategory only under a top-level parent" do
    @new_family.categories.create!(name: "Groceries", color: "#4da568", lucide_icon: "shopping-bag")
    nested = @new_family.categories.create!(name: "Food & Drink", color: "#4da568", lucide_icon: "utensils",
                                            parent: @new_family.categories.find_by!(name: "Groceries"))
    entry = create_transaction(account: @account, category: categories(:subcategory))

    @user.transfer_to_family!(@new_family, role: "admin")

    category = entry.reload.entryable.category
    assert_equal @new_family, category.family
    assert_equal "Restaurants", category.name
    assert_nil category.parent_id
    assert_equal nested.id, @new_family.categories.find_by!(name: "Food & Drink").id
  end

  test "transfer_to_family! keeps automatic category and merchant claims current" do
    entry = create_transaction(account: @account)
    transaction = entry.entryable
    assert transaction.enrich_attributes({ category_id: categories(:food_and_drink).id, merchant_id: merchants(:netflix).id }, source: "ai")
    claimed_at = DataEnrichment.where(enrichable: transaction).pluck(:attribute_name, :updated_at).to_h

    @user.transfer_to_family!(@new_family, role: "admin")

    transaction.reload
    assert_equal @new_family, transaction.category.family
    assert_equal @new_family, transaction.merchant.family
    assert_equal claimed_at, DataEnrichment.where(enrichable: transaction).pluck(:attribute_name, :updated_at).to_h
    assert Transaction.where(id: transaction.id).where(Transaction.enriched_from_sql("category_id", "ai")).exists?
    assert Transaction.where(id: transaction.id).where(Transaction.enriched_from_sql("merchant_id", "ai")).exists?
  end

  test "transfer_to_family! uses a record created concurrently under the same name" do
    entry = create_transaction(account: @account, tags: [ tags(:one) ])
    concurrent = @new_family.tags.create!(name: "Trips", color: "#e99537")
    tags_scope = @new_family.tags
    Family.any_instance.stubs(:tags).returns(tags_scope)
    # The first lookup misses, as if the other insert had not committed yet.
    tags_scope.stubs(:find_by).with(name: "Trips").returns(nil)
    tags_scope.stubs(:create!).raises(ActiveRecord::RecordNotUnique)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_equal [ concurrent ], entry.reload.entryable.tags.to_a
  end

  test "transfer_to_family! copies a record whose stored color no longer validates" do
    categories(:one).update_column(:color, "blue")
    entry = create_transaction(account: @account, category: categories(:one))

    @user.transfer_to_family!(@new_family, role: "admin")

    category = entry.reload.entryable.category
    assert_equal @new_family, category.family
    assert_equal Category.column_defaults["color"], category.color
  end

  test "transfer_to_family! leaves entries of accounts that stay behind untouched" do
    staying = create_transaction(account: accounts(:depository), category: categories(:food_and_drink),
                                 merchant: merchants(:netflix), tags: [ tags(:one) ])

    @user.transfer_to_family!(@new_family, role: "admin")

    transaction = staying.reload.entryable
    assert_equal categories(:food_and_drink), transaction.category
    assert_equal merchants(:netflix), transaction.merchant
    assert_equal [ tags(:one) ], transaction.tags.to_a
  end
end
