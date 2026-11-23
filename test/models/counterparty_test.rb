require "test_helper"

class CounterpartyTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = families(:dylan_family)
    @person = @family.counterparties.create!(name: "Alex", default_currency: "USD", created_by: @admin)
  end

  test "names are unique per creator, ignoring case and spacing" do
    duplicate = @family.counterparties.new(name: "  alex ", default_currency: "USD", created_by: @admin)

    assert_not duplicate.valid?
    assert families(:empty).counterparties.new(name: "Alex", default_currency: "USD").valid?
  end

  test "another member can add a person with a name they can't see" do
    member = users(:family_member)

    assert @family.counterparties.new(name: "Alex", default_currency: "USD", created_by: member).valid?
  end

  test "renaming a person renames their clearing accounts" do
    @person.clearing_account_for!("USD", user: @admin)
    @person.clearing_account_for!("EUR", user: @admin)

    @person.update!(name: "Alexandra")

    assert_equal [ "Alexandra", "Alexandra (EUR)" ], @person.accounts.order(:name).pluck(:name)
  end

  test "forgiving twice books the balance only once" do
    account = @person.clearing_account_for!("USD", user: @admin)
    entry = create_transaction(account: accounts(:depository), amount: 40)
    Counterparty::Assignment.new(entry).update!(@person, user: @admin)

    assert @person.forgive!(account: account)
    assert_nil @person.forgive!(account: account.reload)

    assert_equal 1, account.entries.where(entryable_type: "Transaction").where(amount: 40).count
    assert_equal 0, account.reload.balance
  end

  test "rejects an unknown currency" do
    assert_not @family.counterparties.new(name: "Sam", default_currency: "XXX1").valid?
  end

  test "a clearing account is private even when the family shares accounts by default" do
    @family.update!(default_account_sharing: "shared")

    account = @person.clearing_account_for!("USD", user: @admin)

    assert_empty account.account_shares
    assert_not Account.accessible_by(@member).exists?(account.id)
  end

  test "a new member does not get the family's clearing accounts" do
    @family.update!(default_account_sharing: "shared")
    account = @person.clearing_account_for!("USD", user: @admin)
    AccountShare.where(user: @member).delete_all

    @family.auto_share_existing_accounts_with(@member)

    assert_not AccountShare.exists?(account: account, user: @member)
    assert AccountShare.exists?(account: accounts(:depository), user: @member)
  end

  test "only the creator and people with access to the accounts see a person" do
    @person.clearing_account_for!("USD", user: @admin)

    assert_includes Counterparty.visible_to(@admin), @person
    assert_not_includes Counterparty.visible_to(@member), @person

    @person.accounts.sole.account_shares.create!(user: @member, permission: "read_only")
    assert_includes Counterparty.visible_to(@member), @person
    assert_not @person.manageable_by?(@member)
    assert_not @person.assignable_by?(@member, currency: "USD")
    assert @person.assignable_by?(@admin, currency: "USD")
  end

  test "archiving needs a settled balance" do
    account = @person.clearing_account_for!("USD", user: @admin)
    account.update!(balance: 25)
    assert_not @person.archive!

    account.update!(balance: 0)
    assert @person.archive!
    assert @person.archived?
    assert_not @person.assignable_by?(@admin, currency: "USD")
  end

  test "forgiving books the balance as spending and leaves nothing open" do
    account = @person.clearing_account_for!("USD", user: @admin)
    Counterparty::Assignment.new(create_transaction(account: accounts(:depository), amount: 40)).update!(@person, user: @admin)

    entry = @person.forgive!(account: account, category: categories(:food_and_drink))

    assert_equal 40, entry.amount
    assert_equal "standard", entry.transaction.kind
    assert_equal categories(:food_and_drink), entry.transaction.category
  end

  test "a debt the person forgives is booked as income" do
    account = @person.clearing_account_for!("USD", user: @admin)
    Counterparty::Assignment.new(create_transaction(account: accounts(:depository), amount: -15)).update!(@person, user: @admin)

    assert_equal(-15, @person.forgive!(account: account).amount)
  end

  test "forgiving refuses an account of another person" do
    other = @family.counterparties.create!(name: "Sam", default_currency: "USD", created_by: @admin)
    account = other.clearing_account_for!("USD", user: @admin)

    assert_raises(ArgumentError) { @person.forgive!(account: account) }
  end

  test "clearing accounts can't be picked in imports" do
    assert_not_includes Accountable::USER_SELECTABLE_TYPES, "Clearing"
    assert_includes Accountable::TYPES, "Clearing"
  end
end
