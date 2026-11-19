require "test_helper"

class Counterparty::AssignmentTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)
    @person = @family.counterparties.create!(name: "Alex", default_currency: "USD", created_by: @user)
    @checking = accounts(:depository)
  end

  test "an expense paid for someone becomes a transfer to their clearing account" do
    entry = create_transaction(account: @checking, amount: 60, name: "Concert ticket", category: categories(:food_and_drink))

    leg = Counterparty::Assignment.new(entry).update!(@person, user: @user)

    clearing = @person.accounts.sole
    assert clearing.clearing?
    assert_equal @user, clearing.owner
    assert_equal clearing, leg.account
    assert_equal(-60, leg.amount)
    assert_equal "Concert ticket", leg.name

    transfer = entry.reload.transaction.transfer
    assert transfer.confirmed?
    assert_equal "funds_movement", entry.transaction.kind
    assert_equal entry.transaction, transfer.outflow_transaction
    assert_equal @person, Counterparty::Assignment.new(entry).counterparty
  end

  test "money received from someone lowers what they owe" do
    entry = create_transaction(account: @checking, amount: -40, name: "Payback")

    leg = Counterparty::Assignment.new(entry).update!(@person, user: @user)

    assert_equal 40, leg.amount
    assert_equal entry.transaction, entry.reload.transaction.transfer.inflow_transaction
  end

  test "the clearing balance follows the assigned entries" do
    paid = create_transaction(account: @checking, amount: 100, name: "Dinner", date: 3.days.ago.to_date)
    back = create_transaction(account: @checking, amount: -30, name: "Payback", date: 1.day.ago.to_date)

    Counterparty::Assignment.new(paid).update!(@person, user: @user)
    Counterparty::Assignment.new(back).update!(@person, user: @user)

    clearing = @person.accounts.sole
    Balance::Materializer.new(clearing, strategy: :forward).materialize_balances

    assert_equal 70, clearing.reload.balance
  end

  test "releasing gives the entry back its own kind and removes the leg" do
    entry = create_transaction(account: @checking, amount: 60)
    leg = Counterparty::Assignment.new(entry).update!(@person, user: @user)

    Counterparty::Assignment.new(entry.reload).update!(nil, user: @user)

    assert_not Entry.exists?(leg.id)
    assert_nil entry.reload.transaction.transfer
    assert_equal "standard", entry.transaction.kind
  end

  test "moving to another person replaces the leg" do
    other = @family.counterparties.create!(name: "Sam", default_currency: "USD", created_by: @user)
    entry = create_transaction(account: @checking, amount: 60)
    first_leg = Counterparty::Assignment.new(entry).update!(@person, user: @user)

    second_leg = Counterparty::Assignment.new(entry.reload).update!(other, user: @user)

    assert_not Entry.exists?(first_leg.id)
    assert_equal other.accounts.sole, second_leg.account
    assert_equal other, Counterparty::Assignment.new(entry.reload).counterparty
  end

  test "deleting the bank entry deletes the person's leg" do
    entry = create_transaction(account: @checking, amount: 60)
    leg = Counterparty::Assignment.new(entry).update!(@person, user: @user)

    entry.reload.destroy!

    assert_not Entry.exists?(leg.id)
  end

  test "a payment in another currency opens a second clearing account" do
    entry = create_transaction(account: @checking, amount: 50, currency: "EUR")

    leg = Counterparty::Assignment.new(entry).update!(@person, user: @user)

    assert_equal "EUR", leg.account.currency
    assert_equal "Alex (EUR)", leg.account.name
  end

  test "pending, split parents and other transfers can't be assigned" do
    pending = create_transaction(account: @checking, amount: 10)
    pending.transaction.update!(extra: { "simplefin" => { "pending" => true } })
    assert_not Counterparty::Assignment.new(pending.reload).assignable?

    parent = create_transaction(account: @checking, amount: 100)
    parent.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])
    assert_not Counterparty::Assignment.new(parent.reload).assignable?

    transfer_leg = create_transaction(account: @checking, amount: 25)
    savings_leg = create_transaction(account: accounts(:investment), amount: -25)
    Transfer.create!(inflow_transaction: savings_leg.transaction, outflow_transaction: transfer_leg.transaction, status: "confirmed")
    assert_not Counterparty::Assignment.new(transfer_leg.reload).assignable?
    assert_raises(Counterparty::Assignment::NotAssignable) do
      Counterparty::Assignment.new(transfer_leg).update!(@person, user: @user)
    end
  end

  test "a person from another family is refused" do
    stranger = families(:empty).counterparties.create!(name: "Stranger", default_currency: "USD")
    entry = create_transaction(account: @checking, amount: 10)

    assert_raises(ArgumentError) { Counterparty::Assignment.new(entry).update!(stranger, user: @user) }
    assert_nil entry.reload.transaction.transfer
  end

  test "split parts can each go to a person, and unsplitting removes their legs" do
    parent = create_transaction(account: @checking, amount: 100, name: "Dinner")
    other = @family.counterparties.create!(name: "Sam", default_currency: "USD", created_by: @user)

    parent.split_once!([ { name: "Mine", amount: 50 }, { name: "Alex", amount: 25 }, { name: "Sam", amount: 25 } ]) do |children|
      Counterparty::Assignment.new(children[1]).update!(@person, user: @user)
      Counterparty::Assignment.new(children[2]).update!(other, user: @user)
    end

    children = parent.reload.child_entries.in_split_order.to_a
    assert_equal "standard", children[0].transaction.kind
    assert_equal @person, Counterparty::Assignment.new(children[1]).counterparty
    assert_equal other, Counterparty::Assignment.new(children[2]).counterparty
    legs = [ @person, other ].flat_map { |person| person.accounts.sole.entries.where(entryable_type: "Transaction").to_a }
    assert_equal 2, legs.size

    parent.unsplit_once!

    legs.each { |leg| assert_not Entry.exists?(leg.id) }
    assert_equal "standard", parent.reload.transaction.kind
  end
end
