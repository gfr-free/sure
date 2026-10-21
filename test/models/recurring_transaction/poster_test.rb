require "test_helper"

class RecurringTransaction::PosterTest < ActiveSupport::TestCase
  Poster = RecurringTransaction::Poster

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @today = Date.new(2026, 10, 1)

    travel_to @today.in_time_zone.change(hour: 6) do
      @rent = create_series(name: "Rent", amount: 800, category: categories(:food_and_drink),
                            merchant: merchants(:netflix), notes: "Flat on Main St")
    end
    @occurrence = occurrence_on(@rent, @today)
  end

  test "posts an expense on the due date with the series' details" do
    existing_ids = @account.entries.ids
    assert_difference -> { @account.entries.count }, 1 do
      assert_equal 1, post!
    end

    # Not order(:created_at).last: the post runs under travel_to, so its
    # created_at can be older than the fixtures' when the suite runs later.
    entry = @account.entries.where.not(id: existing_ids).sole
    assert_equal @today, entry.date
    assert_equal 800, entry.amount
    assert_equal "USD", entry.currency
    assert_equal "Rent", entry.name
    assert_equal "Flat on Main St", entry.notes
    assert_equal categories(:food_and_drink), entry.transaction.category
    assert_equal merchants(:netflix), entry.transaction.merchant
    assert_equal "recurring-#{@occurrence.id}", entry.idempotency_key
    assert entry.locked?(:name)
  end

  test "closes the occurrence as paid with an auto-posted allocation that waits for review" do
    post!

    @occurrence.reload
    assert @occurrence.paid?, "the posted entry counts as the payment straight away"
    assert @occurrence.auto_posted_at.present?
    allocation = @occurrence.allocations.sole
    assert allocation.from_auto_posted?
    assert allocation.allocation_confirmed?
    assert allocation.pending_review?
  end

  test "confirming a provisional post only clears the review flag" do
    post!
    allocation = @occurrence.allocations.sole

    RecurringTransaction::Allocator.new(@occurrence).confirm_posted!(allocation)

    assert_not allocation.reload.pending_review?
    assert allocation.from_auto_posted?, "deleting it later must still reopen the date"
    assert @occurrence.reload.paid?
  end

  test "discarding a provisional post deletes the entry and skips the date" do
    post!
    allocation = @occurrence.allocations.sole
    entry = allocation.entry

    resync = RecurringTransaction::Allocator.new(@occurrence).discard_posted!(allocation)

    assert_equal({ @account => entry.date }, resync)
    assert_not Entry.exists?(entry.id)
    assert @occurrence.reload.skipped?
    assert_empty @occurrence.allocations
    assert_no_difference -> { Entry.count } do
      post!
    end
  end

  test "discarding refuses a post that was confirmed in the meantime" do
    post!
    allocation = @occurrence.allocations.sole
    stale = RecurringAllocation.find(allocation.id)
    RecurringTransaction::Allocator.new(@occurrence).confirm_posted!(allocation)

    assert_raises(RecurringTransaction::Allocator::NotPendingReviewError) do
      RecurringTransaction::Allocator.new(@occurrence).discard_posted!(stale)
    end
    assert @occurrence.reload.paid?
    assert Entry.exists?(allocation.entry_id)
  end

  test "discarding keeps the date open when another payment is recorded on it" do
    @occurrence.override_amount!(1600)
    post!
    allocation = @occurrence.allocations.sole
    RecurringTransaction::Allocator.new(@occurrence).allocate!(amount: 50)

    RecurringTransaction::Allocator.new(@occurrence).discard_posted!(allocation)

    assert @occurrence.reload.scheduled?, "the user's own payment must not end up on a skipped date"
    assert_equal [ 50 ], @occurrence.allocations.pluck(:allocated_amount)
  end

  test "post now needs no review" do
    future = occurrence_on(@rent, @today + 10)

    Poster.new(@family, today: @today).post_now!(future)

    assert_not future.reload.allocations.sole.pending_review?
  end

  test "discarding a provisional transfer deletes both legs" do
    transfer_series = travel_to(@today) do
      create_series(name: "Card payment", amount: 200, destination_account: accounts(:credit_card))
    end
    occurrence = occurrence_on(transfer_series, @today)
    post!
    allocation = occurrence.reload.allocations.sole
    transfer = allocation.entry.transaction.transfer
    leg_ids = [ transfer.outflow_transaction.entry.id, transfer.inflow_transaction.entry.id ]

    assert_difference -> { Transfer.count }, -1 do
      RecurringTransaction::Allocator.new(occurrence).discard_posted!(allocation)
    end

    assert_empty Entry.where(id: leg_ids)
    assert occurrence.reload.skipped?
  end

  test "the matcher does not attach another entry to a date with a provisional post" do
    post!
    typed = @account.entries.create!(date: @today, name: "Rent", amount: 800, currency: "USD",
                                     entryable: Transaction.new)

    RecurringTransaction::Matcher.new(@family).run!

    assert_empty RecurringAllocation.where(entry: typed)
    assert_equal 1, @occurrence.reload.allocations.count
  end

  test "posts income with a negative amount" do
    salary = travel_to(@today) { create_series(name: "Salary", amount: -3000) }
    occurrence_on(salary, @today)

    post!

    entry = @account.entries.find_by(name: "Salary")
    assert_equal(-3000, entry.amount)
  end

  test "uses the amount set for one occurrence" do
    @occurrence.override_amount!(850)

    post!

    assert_equal 850, @account.entries.find_by(name: "Rent").amount
  end

  test "a second run posts nothing" do
    post!

    assert_no_difference -> { Entry.count } do
      assert_equal 0, post!
    end
  end

  test "deleting the posted entry reopens the occurrence without re-posting it" do
    post!
    entry = @account.entries.find_by(name: "Rent")

    entry.destroy!

    @occurrence.reload
    assert @occurrence.scheduled?, "the payment did not happen as posted, so the date is open again"
    assert_empty @occurrence.allocations

    assert_no_difference -> { Entry.count } do
      post!
    end
  end

  test "deleting a posted entry that lost its key, as after an import, still reopens the date" do
    post!
    entry = @occurrence.allocations.sole.entry
    entry.update_columns(idempotency_key: nil)

    entry.destroy!

    assert @occurrence.reload.scheduled?
    assert_empty @occurrence.allocations
  end

  test "deleting an entry the user attached keeps the payment" do
    entry = @account.entries.create!(date: @today, name: "Rent", amount: 800, currency: "USD",
                                     entryable: Transaction.new)
    RecurringTransaction::Allocator.new(@occurrence).allocate!(entry: entry)

    entry.destroy!

    assert @occurrence.reload.paid?
    assert_nil @occurrence.allocations.sole.entry_id
  end

  test "does not post a skipped occurrence" do
    @occurrence.skip!

    assert_no_difference -> { Entry.count } do
      post!
    end
  end

  test "does not post an occurrence that already has a payment or a suggestion" do
    RecurringTransaction::Allocator.new(@occurrence).allocate!(amount: 300)

    assert_no_difference -> { Entry.count } do
      post!
    end
  end

  test "does not post future dates" do
    @occurrence.update!(due_on: @today + 1, original_due_on: @today + 1)

    assert_no_difference -> { Entry.count } do
      post!
    end
  end

  test "does not post dates before auto-posting was switched on" do
    @occurrence.update!(due_on: @today - 1, original_due_on: @today - 1)

    assert_no_difference -> { Entry.count } do
      post!
    end
  end

  test "catches up on dates missed while the job did not run" do
    later = occurrence_on(@rent, @today + 7)

    assert_equal 2, post!(today: @today + 8)
    assert later.reload.paid?
  end

  test "does not post for a paused series" do
    @rent.update!(status: "paused")

    assert_no_difference -> { Entry.count } do
      post!
    end
  end

  test "does not post for a series without auto-posting" do
    @rent.update!(auto_post: false)

    assert_no_difference -> { Entry.count } do
      post!
    end
  end

  test "stops auto-posting once the account is linked to a provider" do
    @rent.update_columns(account_id: accounts(:connected).id)

    assert_difference -> { DebugLogEntry.where(category: "recurring_auto_post").count }, 1 do
      assert_no_difference -> { Entry.count } do
        post!
      end
    end

    assert_not @rent.reload.auto_post?
    assert_equal :linked, @rent.auto_post_stop_reason
  end

  test "switching auto-posting off by hand reports no stop" do
    @rent.update!(auto_post: false)

    assert_nil @rent.reload.auto_post_from
    assert_nil @rent.auto_post_stop_reason
  end

  test "posts a transfer between two manual accounts" do
    destination = accounts(:credit_card)
    transfer_series = travel_to(@today) do
      create_series(name: "Card payment", amount: 200, destination_account: destination)
    end
    occurrence = occurrence_on(transfer_series, @today)

    assert_difference -> { Transfer.count }, 1 do
      post!
    end

    allocation = occurrence.reload.allocations.sole
    assert_equal @account, allocation.entry.account
    assert_equal 200, allocation.entry.amount
    assert occurrence.paid?
  end

  test "the matcher leaves a posted entry alone" do
    post!
    entry = @account.entries.find_by(name: "Rent")
    next_month = occurrence_on(@rent, @today.next_month)

    RecurringTransaction::Matcher.new(@family).run!

    assert_equal [ @occurrence.id ], RecurringAllocation.where(entry: entry).pluck(:recurring_occurrence_id)
    assert_empty next_month.reload.allocations
  end

  test "does not post a date the user already paid by hand" do
    manual = @account.entries.create!(
      date: @today - 1, name: "Rent", amount: 800, currency: "USD",
      entryable: Transaction.new(merchant: merchants(:netflix))
    )

    assert_no_difference -> { @account.entries.count } do
      assert_equal 0, post!
    end

    allocation = @occurrence.reload.allocations.sole
    assert_equal manual, allocation.entry
    assert_not allocation.from_auto_posted?
    assert_nil @occurrence.auto_posted_at
  end

  test "skips the matching pass when nothing is due" do
    @occurrence.update!(due_on: @today + 5, original_due_on: @today + 5)
    RecurringTransaction::Matcher.any_instance.expects(:run!).never

    assert_equal 0, post!
  end

  test "a failing matching pass posts nothing and is logged" do
    RecurringTransaction::Matcher.any_instance.stubs(:run!).raises(StandardError, "boom")

    assert_difference -> { DebugLogEntry.where(category: "recurring_auto_post", level: "error").count }, 1 do
      assert_no_difference -> { Entry.count } do
        assert_equal 0, post!
      end
    end
    assert_nil @occurrence.reload.auto_posted_at
  end

  test "a snooze saved during the run wins" do
    RecurringTransaction::Matcher.any_instance.stubs(:run!).with do
      @occurrence.update_columns(snoozed_until: @today + 7)
      true
    end

    assert_equal 0, post!
    assert_nil @occurrence.reload.auto_posted_at
  end

  test "a switch-off saved during the run wins" do
    RecurringTransaction::Matcher.any_instance.stubs(:run!).with do
      @rent.update_columns(auto_post: false)
      true
    end

    assert_equal 0, post!
    assert_nil @occurrence.reload.auto_posted_at
  end

  test "a snoozed date waits for its snooze and posts on that day" do
    @occurrence.snooze!(@today + 4)

    assert_no_difference -> { Entry.count } do
      post!
    end

    post!(today: @today + 4)
    assert_equal @today + 4, @account.entries.find_by(name: "Rent").date
  end

  test "does not post into a disabled account and keeps auto-posting on" do
    @account.disable!

    assert_no_difference -> { Entry.count } do
      post!
    end

    assert @rent.reload.auto_post?
    assert @occurrence.reload.scheduled?
  end

  test "rebuilding the schedule keeps a posted date whose entry was deleted" do
    post!
    @account.entries.find_by(name: "Rent").destroy!

    travel_to(@today.in_time_zone.change(hour: 6)) do
      RecurringTransaction::OccurrenceGenerator.new(@rent).regenerate_future!
    end

    assert @rent.recurring_occurrences.where(due_on: @occurrence.due_on).where.not(auto_posted_at: nil).exists?,
      "the date keeps its stamp through regeneration"
    assert_no_difference -> { Entry.count } do
      post!
    end
  end

  test "pausing and resuming keeps a posted date whose entry was deleted from posting again" do
    @occurrence.destroy!
    future = occurrence_on(@rent, @today + 31)
    post_now!(future).destroy!

    travel_to(@today.in_time_zone.change(hour: 6)) do
      @rent.mark_inactive!
      @rent.mark_active!
    end

    row = @rent.recurring_occurrences.find_by!(original_due_on: @today + 31)
    assert row.auto_posted_at.present?
    post!(today: @today + 31)
    assert_empty row.reload.allocations, "the deleted post must not come back"
  end

  test "a weekend shift keeps the stamp of a posted date and moves it" do
    @occurrence.destroy!
    sunday = Date.new(2026, 11, 1)
    future = occurrence_on(@rent, sunday)
    post_now!(future).destroy!

    travel_to(@today.in_time_zone.change(hour: 6)) do
      @rent.update!(weekend_adjust: "after")
    end

    row = @rent.recurring_occurrences.find_by(original_due_on: sunday)
    assert row.auto_posted_at.present?
    assert_equal Date.new(2026, 11, 2), row.due_on
    post!(today: Date.new(2026, 11, 2))
    assert_empty row.reload.allocations, "the deleted post must not come back"
  end

  test "a failing series is logged and does not stop the others" do
    transfer_series = travel_to(@today) do
      create_series(name: "Card payment", amount: 200, destination_account: accounts(:credit_card))
    end
    failing = occurrence_on(transfer_series, @today)
    Transfer::Creator.any_instance.stubs(:create).raises(StandardError, "boom")

    assert_difference -> { DebugLogEntry.where(category: "recurring_auto_post", level: "error").count }, 1 do
      assert_equal 1, post!
    end

    assert failing.reload.scheduled?
    assert_nil failing.auto_posted_at
    assert @occurrence.reload.paid?
  end

  test "post now books an open future date today and closes it" do
    future = occurrence_on(@rent, @today + 10)
    existing_ids = @account.entries.ids

    entry = post_now!(future)

    assert_equal entry, @account.entries.where.not(id: existing_ids).sole
    assert_equal @today, entry.date, "dated the day it was posted, not the due date"
    assert_equal 800, entry.amount
    assert_match(/\Arecurring-#{future.id}-now-/, entry.idempotency_key)
    future.reload
    assert future.paid?
    assert future.auto_posted_at.present?
    assert future.allocations.sole.from_auto_posted?
  end

  test "post now does not need the auto-post switch" do
    @rent.update!(auto_post: false)

    assert post_now!(@occurrence)
    assert @occurrence.reload.paid?
  end

  test "the nightly run does not post a date posted by hand again" do
    post_now!(@occurrence)

    assert_no_difference -> { Entry.count } do
      assert_equal 0, post!
    end
  end

  test "post now refuses a date that already has a payment or is skipped" do
    RecurringTransaction::Allocator.new(@occurrence).allocate!(amount: 300)
    skipped = occurrence_on(@rent, @today + 30)
    skipped.skip!

    assert_no_difference -> { Entry.count } do
      assert_nil post_now!(@occurrence)
      assert_nil post_now!(skipped)
    end
  end

  test "post now refuses a linked account or a variable amount" do
    @rent.update_columns(account_id: accounts(:connected).id)
    assert_nil post_now!(@occurrence.reload)

    @rent.update_columns(account_id: @account.id, amount_strategy: "average")
    assert_nil post_now!(@occurrence.reload)
  end

  test "post now can post again after its entry was deleted" do
    post_now!(@occurrence).destroy!
    assert @occurrence.reload.scheduled?

    assert post_now!(@occurrence)
    assert @occurrence.reload.paid?
  end

  test "post now books a new entry when the nightly one was unlinked, not the old one" do
    post!
    nightly = @occurrence.allocations.sole.entry
    RecurringTransaction::Allocator.new(@occurrence).unallocate!(@occurrence.allocations.sole)
    assert @occurrence.reload.scheduled?

    entry = post_now!(@occurrence, today: @today + 3)

    assert_not_equal nightly, entry
    assert_equal @today + 3, entry.date
    assert_equal entry, @occurrence.reload.allocations.sole.entry
  end

  test "post now books a transfer between two manual accounts" do
    transfer_series = travel_to(@today) do
      create_series(name: "Savings", amount: 200, destination_account: accounts(:credit_card))
    end
    occurrence = occurrence_on(transfer_series, @today + 5)

    entry = nil
    assert_difference -> { Transfer.count }, 1 do
      entry = post_now!(occurrence)
    end
    assert_equal @today, entry.date
    assert entry.transaction.transfer.present?
  end

  test "discarding a plain post keeps the other account's entry it was matched with" do
    post!
    allocation = @occurrence.allocations.sole
    posted = allocation.entry
    card_entry = accounts(:credit_card).entries.create!(date: @today, name: "PAYMENT RECEIVED", amount: -800,
                                                        currency: "USD", entryable: Transaction.new)
    @family.auto_match_transfers!
    assert posted.reload.entryable.transfer.present?, "precondition: the matcher paired the two"

    RecurringTransaction::Allocator.new(@occurrence).discard_posted!(allocation.reload)

    assert_not Entry.exists?(posted.id)
    assert Entry.exists?(card_entry.id)
  end

  test "a bill whose account changed currency stops posting" do
    @account.update!(currency: "EUR")

    assert_no_difference -> { Entry.count } do
      post!
    end

    assert_not @rent.reload.auto_post?
    assert @occurrence.reload.scheduled?
  end

  test "post now returns nil for a transfer into another currency without a rate" do
    card = accounts(:credit_card)
    card.update_columns(currency: "EUR")
    transfer_series = travel_to(@today) do
      create_series(name: "Card payment", amount: 200, destination_account: card)
    end
    occurrence = occurrence_on(transfer_series, @today + 5)
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_no_difference -> { Entry.count } do
      assert_nil post_now!(occurrence)
    end
    assert occurrence.reload.scheduled?
  end

  test "moving the bill's day drops a reopened posted date instead of keeping it as an extra" do
    future = occurrence_on(@rent, @today + 31)
    post_now!(future).destroy!

    travel_to(@today.in_time_zone.change(hour: 6)) do
      @rent.update!(expected_day_of_month: 15)
      RecurringTransaction::OccurrenceGenerator.new(@rent).regenerate_future!
    end

    assert_not @rent.recurring_occurrences.open_status.exists?(due_on: @today + 31)
  end

  private
    def post_now!(occurrence, today: @today)
      travel_to(today.in_time_zone.change(hour: 6)) { Poster.new(@family, today: today).post_now!(occurrence) }
    end

    def post!(today: @today)
      travel_to(today.in_time_zone.change(hour: 6)) { Poster.new(@family, today: today).post_due! }
    end

    def create_series(name:, amount:, **attrs)
      series = @family.recurring_transactions.create!(
        account: @account,
        name: name,
        amount: amount,
        currency: "USD",
        expected_day_of_month: 1,
        last_occurrence_date: Date.current,
        next_expected_date: Date.current,
        status: "active",
        manual: true,
        auto_post: true,
        **attrs
      )
      # The generator materializes its own window; the tests place exactly the
      # dates they talk about.
      series.recurring_occurrences.delete_all
      series
    end

    def occurrence_on(series, date)
      series.recurring_occurrences.create!(family: @family, original_due_on: date, due_on: date, currency: "USD")
    end
end
