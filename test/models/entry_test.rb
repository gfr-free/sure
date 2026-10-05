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

  test "auto_exclude_stale_pending notes why it excluded the entry" do
    account = accounts(:depository)
    travel_to Time.zone.parse("2026-10-03 06:00:00")
    stale = create_pending(account, date: 10.days.ago.to_date, amount: 40)
    stale.update_columns(source: "simplefin")
    fresh = create_pending(account, date: 2.days.ago.to_date, amount: 41)

    assert_equal 1, Entry.auto_exclude_stale_pending(account: account)

    stale.reload
    assert stale.excluded?
    note = stale.auto_exclusion
    assert_equal "excluded", note["action"]
    assert_equal "stale_pending", note["reason"]
    assert_equal "sync:simplefin", note["by"]
    assert_equal 8, note["days"]
    assert_equal Time.zone.parse("2026-10-03 06:00:00"), Time.zone.parse(note["at"])
    assert stale.transaction.extra.dig("simplefin", "pending"), "provider data stays untouched"

    assert_not fresh.reload.excluded?
    assert_nil fresh.transaction.extra[Entry::AUTO_MUTATION_KEY]
  end

  test "auto_exclude_stale_pending leaves entries the user already excluded alone" do
    account = accounts(:depository)
    manual = create_pending(account, date: 10.days.ago.to_date, amount: 40)
    manual.update!(excluded: true)

    assert_equal 0, Entry.auto_exclude_stale_pending(account: account)
    assert_nil manual.reload.auto_exclusion
  end

  test "reconcile_pending_duplicates notes the posted match it excluded the pending for" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 25)
    pending.update_columns(source: "enable_banking")
    booked = create_transaction(account: account, date: 1.day.ago.to_date, amount: 25)

    Entry.reconcile_pending_duplicates(account: account)

    note = pending.reload.auto_exclusion
    assert pending.excluded?
    assert_equal "posted_match", note["reason"]
    assert_equal "sync:enable_banking", note["by"]
    assert_equal booked.id, note["matched_entry_id"]
    assert note["at"].present?
  end

  test "reconcile_pending_duplicates dry run writes no note" do
    account = accounts(:depository)
    pending = create_pending(account, date: 3.days.ago.to_date, amount: 25)
    create_transaction(account: account, date: 1.day.ago.to_date, amount: 25)

    Entry.reconcile_pending_duplicates(account: account, dry_run: true)

    assert_not pending.reload.excluded?
    assert_nil pending.transaction.extra[Entry::AUTO_MUTATION_KEY]
  end

  test "turning exclude off by hand removes the automatic exclusion note" do
    account = accounts(:depository)
    pending = create_pending(account, date: 10.days.ago.to_date, amount: 40)
    Entry.auto_exclude_stale_pending(account: account)
    assert pending.reload.auto_exclusion

    pending.update!(excluded: false)

    assert_nil pending.reload.transaction.extra[Entry::AUTO_MUTATION_KEY]
    assert pending.transaction.extra.dig("simplefin", "pending")
  end

  test "excluding by hand writes no automatic exclusion note" do
    entry = create_transaction(account: accounts(:depository))

    entry.update!(excluded: true)

    assert entry.reload.excluded?
    assert_nil entry.auto_exclusion
    assert_nil entry.transaction.extra[Entry::AUTO_MUTATION_KEY]
  end

  test "exclude_automatically! rejects unknown reasons" do
    entry = create_transaction(account: accounts(:depository))

    assert_raises(ArgumentError) { entry.exclude_automatically!(reason: "whatever") }
    assert_not entry.reload.excluded?
  end

  private
    def create_pending(account, date:, amount:)
      create_transaction(
        account: account, date: date, amount: amount,
        entryable: Transaction.new(extra: { "simplefin" => { "pending" => true } })
      )
    end
end
