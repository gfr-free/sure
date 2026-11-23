require "test_helper"

class Transaction::ReviewableTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @entry = create_transaction(name: "Reviewable", category: categories(:food_and_drink))
    @transaction = @entry.transaction
  end

  test "rejects an unknown review state" do
    @transaction.review_state = "done"

    assert_not @transaction.valid?
    assert_raises(ArgumentError) { Transaction.set_review_state!(Transaction.where(id: @transaction.id), "done", user: @admin) }
  end

  test "the database refuses an unknown review state too" do
    assert_raises(ActiveRecord::StatementInvalid) { @transaction.update_column(:review_state, "done") }
  end

  test "sets the mark with who and when, and touches the entry" do
    @entry.update_column(:updated_at, 1.day.ago)

    travel_to Time.zone.parse("2026-11-20 10:00") do
      assert_equal 1, Transaction.set_review_state!(Transaction.where(id: @transaction.id), "flagged", user: @admin)
    end

    @transaction.reload
    assert @transaction.review_flagged?
    assert_equal Time.zone.parse("2026-11-20 10:00"), @transaction.review_state_changed_at
    assert_equal @admin, @transaction.review_state_changed_by
    assert_equal Time.zone.parse("2026-11-20 10:00"), @entry.reload.updated_at
  end

  test "reviewed replaces flagged, and clearing removes who and when" do
    scope = Transaction.where(id: @transaction.id)
    Transaction.set_review_state!(scope, "flagged", user: @admin)
    Transaction.set_review_state!(scope, "reviewed", user: @member)

    @transaction.reload
    assert @transaction.reviewed?
    assert_equal @member, @transaction.review_state_changed_by

    Transaction.set_review_state!(scope, nil, user: @admin)

    @transaction.reload
    assert_nil @transaction.review_state
    assert_nil @transaction.review_state_changed_at
    assert_nil @transaction.review_state_changed_by_id
  end

  test "setting the same mark again changes nothing" do
    scope = Transaction.where(id: @transaction.id)
    Transaction.set_review_state!(scope, "flagged", user: @admin)
    first_changed_at = @transaction.reload.review_state_changed_at

    assert_equal 0, Transaction.set_review_state!(scope, "flagged", user: @member)
    assert_equal first_changed_at, @transaction.reload.review_state_changed_at
    assert_equal @admin, @transaction.review_state_changed_by
  end

  test "deleting the user keeps the mark and forgets who set it" do
    user = @admin.family.users.create!(email: "reviewer@example.com", password: "Password1!secure", first_name: "Re", last_name: "Viewer", role: "member")
    Transaction.set_review_state!(Transaction.where(id: @transaction.id), "reviewed", user: user)

    user.delete

    @transaction.reload
    assert @transaction.reviewed?
    assert_nil @transaction.review_state_changed_by_id
  end

  test "a split keeps the parent's mark on every part" do
    Transaction.set_review_state!(Transaction.where(id: @transaction.id), "flagged", user: @admin)
    @entry.reload

    children = @entry.split!([
      { name: "Part A", amount: 60, category_id: nil },
      { name: "Part B", amount: 40, category_id: nil }
    ])

    children.each do |child|
      assert child.transaction.review_flagged?
      assert_equal @admin.id, child.transaction.review_state_changed_by_id
    end
  end

  test "unsplitting flags the parent when any part was flagged" do
    children = @entry.split!([
      { name: "Part A", amount: 60, category_id: nil },
      { name: "Part B", amount: 40, category_id: nil }
    ])
    Transaction.set_review_state!(Transaction.where(id: children.first.entryable_id), "reviewed", user: @admin)
    Transaction.set_review_state!(Transaction.where(id: children.last.entryable_id), "flagged", user: @member)

    @entry.reload.unsplit!

    @transaction.reload
    assert @transaction.review_flagged?
    assert_equal @member.id, @transaction.review_state_changed_by_id
  end

  test "unsplitting marks the parent reviewed only when every part was" do
    children = @entry.split!([
      { name: "Part A", amount: 60, category_id: nil },
      { name: "Part B", amount: 40, category_id: nil }
    ])
    Transaction.set_review_state!(Transaction.where(id: children.first.entryable_id), "reviewed", user: @admin)

    @entry.reload.unsplit!
    assert_nil @transaction.reload.review_state

    children = @entry.reload.split!([
      { name: "Part A", amount: 60, category_id: nil },
      { name: "Part B", amount: 40, category_id: nil }
    ])
    Transaction.set_review_state!(Transaction.where(id: children.map(&:entryable_id)), "reviewed", user: @admin)

    @entry.reload.unsplit!
    assert @transaction.reload.reviewed?
  end

  test "editing a split keeps each part's own mark" do
    children = @entry.split!([
      { name: "Part A", amount: 60, category_id: nil },
      { name: "Part B", amount: 40, category_id: nil }
    ])
    Transaction.set_review_state!(Transaction.where(id: children.first.entryable_id), "reviewed", user: @admin)

    assert @entry.reload.resplit!([
      { name: "Part A", amount: 70, category_id: nil },
      { name: "Part B", amount: 30, category_id: nil }
    ])

    parts = @entry.reload.child_entries.order(:created_at).map(&:transaction)
    assert parts.first.reviewed?
    assert_nil parts.last.review_state
  end

  test "the automatic pending to posted reconcile carries the mark to the booked copy" do
    pending = create_transaction(name: "Coffee", amount: 7, date: 2.days.ago.to_date, source: "simplefin", external_id: "rv_pending")
    pending.transaction.update!(extra: { "simplefin" => { "pending" => true } })
    posted = create_transaction(name: "Coffee", amount: 7, date: 1.day.ago.to_date, source: "simplefin", external_id: "rv_posted")
    Transaction.set_review_state!(Transaction.where(id: pending.entryable_id), "flagged", user: @admin)

    Entry.reconcile_pending_duplicates(account: pending.account)

    assert pending.reload.excluded?
    assert posted.reload.transaction.review_flagged?
  end

  test "a provider sync of the same transaction keeps the mark" do
    adapter = Account::ProviderImportAdapter.new(accounts(:depository))
    entry = adapter.import_transaction(external_id: "review_sync_1", amount: 12, currency: "USD",
                                       date: Date.current, name: "Synced", source: "plaid")
    Transaction.set_review_state!(Transaction.where(id: entry.entryable_id), "flagged", user: @admin)

    adapter.import_transaction(external_id: "review_sync_1", amount: 13, currency: "USD",
                               date: Date.current, name: "Synced again", source: "plaid",
                               category_id: categories(:income).id)

    transaction = entry.reload.transaction
    assert_equal 13, entry.amount
    assert transaction.review_flagged?
    assert_equal @admin.id, transaction.review_state_changed_by_id
  end
end
