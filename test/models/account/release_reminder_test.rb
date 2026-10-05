require "test_helper"

class Account::ReleaseReminderTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2026, 10, 5)
  end

  test "reminds before the release date within the lead time" do
    account = locked_account(available_on: @today + 14)

    reminder = build(account, lead_days: 14)

    assert_equal "upcoming", reminder.kind
    assert_equal @today + 14, reminder.release_on
    assert_equal 14, reminder.days_until
  end

  test "says nothing while the release date is further out than the lead time" do
    assert_nil build(locked_account(available_on: @today + 15), lead_days: 14)
  end

  test "reports a release on the day and for a week after" do
    account = locked_account(available_on: @today)

    assert_equal "released", build(account, lead_days: 14).kind
    assert_equal "released", build(account, lead_days: 14, date: @today + 6).kind
    assert_nil build(account, lead_days: 14, date: @today + 7)
  end

  test "ignores accounts that are not locked until a date" do
    assert_nil build(create_account(Depository, "savings"), lead_days: 14)
    assert_nil build(locked_account(available_on: nil), lead_days: 14)
  end

  test "a renewing deposit is reminded ahead of the last day to give notice" do
    account = locked_account(available_on: @today + 40, auto_renew: true, renewal_term_months: 12, notice_period_days: 30)

    assert_nil build(account, lead_days: 7, date: @today + 2)

    reminder = build(account, lead_days: 7, date: @today + 3)
    assert_equal "renewal", reminder.kind
    assert_equal @today + 40, reminder.release_on
    assert_equal @today + 10, reminder.cancel_by
    assert reminder.notice_open?

    assert_nil build(account, lead_days: 7, date: @today + 11)
  end

  test "a renewing deposit stays reminded during its grace period" do
    account = locked_account(available_on: @today, auto_renew: true, renewal_term_months: 12, grace_days: 10)

    reminder = build(account, lead_days: 14, date: @today + 10)

    assert_equal "renewal", reminder.kind
    assert_equal @today, reminder.release_on
    assert_equal @today + 10, reminder.grace_until
    assert_not reminder.notice_open?
    assert_nil build(account, lead_days: 14, date: @today + 11)
  end

  test "a notice period longer than the time left moves on to the next renewal" do
    # Renews every 3 months with 80 days' notice: the renewal in 5 days can no
    # longer be stopped, but notice for the one after it (due 22 Oct) falls
    # within the lead time.
    account = locked_account(available_on: @today + 5, auto_renew: true, renewal_term_months: 3, notice_period_days: 80)

    reminder = build(account, lead_days: 20)

    assert_equal (@today + 5) >> 3, reminder.release_on
    assert_equal Date.new(2026, 10, 22), reminder.cancel_by
  end

  test "lists reminders by release date" do
    later = locked_account(available_on: @today + 10, name: "Later")
    sooner = locked_account(available_on: @today + 3, name: "Sooner")

    reminders = Account::ReleaseReminder.for([ later, sooner ], date: @today, lead_days: 14)

    assert_equal [ sooner, later ], reminders.map(&:account)
  end

  test "candidates skip disabled accounts" do
    account = locked_account(available_on: @today + 3)
    account.disable!

    assert_not_includes Account::ReleaseReminder.candidates(@family.accounts), account
  end

  private
    def build(account, lead_days:, date: @today)
      Account::ReleaseReminder.build(account, date: date, lead_days: lead_days)
    end

    def locked_account(available_on:, name: "Term deposit", **attributes)
      @family.accounts.create!(
        name: name,
        balance: 5000,
        currency: "USD",
        owner: users(:family_admin),
        accountable: Depository.new(subtype: "cd"),
        available_on: available_on,
        **attributes
      )
    end

    def create_account(klass, subtype)
      @family.accounts.create!(name: "#{klass.name} #{subtype}", balance: 1000, currency: "USD",
                               owner: users(:family_admin), accountable: klass.new(subtype: subtype))
    end
end
