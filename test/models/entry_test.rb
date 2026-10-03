require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "chronological ordering uses id as final tie breaker" do
    account = accounts(:depository)
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 3.times.map do |index|
      create_transaction(
        account: account,
        name: "Same timestamp transaction #{index}",
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    entry_ids = entries.map(&:id)

    assert_equal entry_ids.sort, Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal entry_ids.sort.reverse, Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end

  test "reconcile_pending_duplicates excludes a pending with one unambiguous booked match" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 25)
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 25)

    Entry.reconcile_pending_duplicates(account: account)

    assert pending.reload.excluded?
  end

  test "reconcile_pending_duplicates keeps both same-amount pendings when only one booked" do
    account = accounts(:depository)
    first = create_pending(account, date: 3.days.ago.to_date, amount: 20)
    second = create_pending(account, date: 2.days.ago.to_date, amount: 20)
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 20)

    Entry.reconcile_pending_duplicates(account: account)

    assert_not first.reload.excluded?
    assert_not second.reload.excluded?
  end

  test "reconcile_pending_duplicates ignores a booked entry from another provider" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 30)
    pending.update_columns(source: "simplefin")
    booked = create_transaction(account: account, date: 1.day.ago.to_date, amount: 30)
    booked.update_columns(source: "lunchflow")

    Entry.reconcile_pending_duplicates(account: account)

    assert_not pending.reload.excluded?
  end

  private
    def create_pending(account, date:, amount:)
      create_transaction(
        account: account, date: date, amount: amount,
        entryable: Transaction.new(extra: { "simplefin" => { "pending" => true } })
      )
    end
end
