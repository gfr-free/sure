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
    assert_difference -> { @account.entries.count }, 1 do
      assert_equal 1, post!
    end

    entry = @account.entries.order(:created_at).last
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

  test "closes the occurrence as paid with an auto-posted allocation" do
    post!

    @occurrence.reload
    assert @occurrence.paid?
    assert @occurrence.auto_posted_at.present?
    allocation = @occurrence.allocations.sole
    assert allocation.from_auto_posted?
    assert allocation.allocation_confirmed?
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

  private
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
