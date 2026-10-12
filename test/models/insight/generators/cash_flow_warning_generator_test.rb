require "test_helper"

class Insight::Generators::CashFlowWarningGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    # Share family accounts with family_member so they're accessible to all active members
    # except connected, which should remain private for tests that check private account behavior
    connected_id = accounts(:connected).id
    @family.accounts.each do |account|
      next if account.owner_id == users(:family_member).id || account.id == connected_id
      account.account_shares.find_or_create_by(user: users(:family_member)) do |share|
        share.permission = "read_only"
      end
    end

    @series = @family.recurring_transactions.create!(
      name: "Horizon Power", account: accounts(:depository), amount: 100, currency: "USD",
      expected_day_of_month: 15, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, status: "active", manual: true
    )
    # The series generates its own horizon on create; clear it so the test
    # owns exactly three known occurrences.
    @series.recurring_occurrences.delete_all
    @occurrences = 3.times.map do |i|
      @series.recurring_occurrences.create!(
        family: @family,
        original_due_on: Date.current + i + 1,
        due_on: Date.current + i + 1,
        currency: "USD"
      )
    end
    RecurringAllocation.create!(
      recurring_occurrence: @occurrences.first, state: :confirmed, source: :user_confirmed,
      allocated_amount: 40, currency: "USD", paid_on: Date.current
    )
  end

  test "remaining amounts come from one grouped sum, not one query per occurrence" do
    generator = Insight::Generators::CashFlowWarningGenerator.new(@family)

    sum_queries = 0
    counter = ->(*, payload) do
      sum_queries += 1 if payload[:sql].to_s.match?(/SUM.*recurring_allocations/i)
    end

    entries = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      generator.send(:upcoming_recurring_entries)
    end

    assert_equal 1, sum_queries, "the confirmed-allocation sums must batch into one grouped query"
    assert_equal [ 60, 100, 100 ], entries.sort_by(&:date).map(&:amount).map(&:to_i),
      "the partially paid occurrence contributes only its remainder"
  end

  test "the projection starts from money reachable today, not from every deposit account" do
    cd = @family.accounts.create!(
      name: "Term deposit", balance: 10_000, currency: "USD", accountable: Depository.new(subtype: "cd"),
      available_on: Date.current + 90
    )
    brokerage = @family.accounts.create!(
      name: "Brokerage", balance: 10_000, currency: "USD", accountable: Investment.new(subtype: "brokerage")
    )
    # Share new accounts with family_member so they're accessible to all
    [ cd, brokerage ].each do |account|
      account.account_shares.create!(user: users(:family_member), permission: "read_only")
    end

    cash_accounts = Insight::Generators::CashFlowWarningGenerator.new(@family).send(:cash_accounts)

    assert_includes cash_accounts, accounts(:depository)
    assert_not_includes cash_accounts, cd
    assert_not_includes cash_accounts, brokerage

    cd.update!(available_on: Date.current)

    assert_includes Insight::Generators::CashFlowWarningGenerator.new(@family).send(:cash_accounts), cd
  end

  # The feed is shared by the whole family: `connected` is private to
  # family_admin, so its balance must not cover the shared projection.
  test "a private cash account does not feed the projected balance" do
    accounts(:depository).update_columns(balance: 100)
    accounts(:connected).update_columns(balance: 50_000)

    generator = Insight::Generators::CashFlowWarningGenerator.new(@family)

    # Debug: check account shares
    warn "\n=== ACCOUNT SHARES ===\n#{@family.accounts.map { |a| "#{a.name}: shares=#{a.account_shares.count}" }.join("\n")}\n"

    # Debug: check accessible_by_all_active_members
    accessible = @family.accounts.accessible_by_all_active_members
    warn "\n=== ACCESSIBLE BY ALL ===\nCount: #{accessible.count}\n#{accessible.map { |a| "#{a.name} (liquidity=#{a.liquidity})" }.join("\n")}\n"

    # Debug: check visible
    accessible_visible = accessible.visible
    warn "\n=== ACCESSIBLE + VISIBLE ===\nCount: #{accessible_visible.count}\n#{accessible_visible.map { |a| "#{a.name}" }.join("\n")}\n"

    # Debug: check depository filter
    depository_filtered = accessible_visible.where(accountable_type: "Depository", currency: @family.currency)
    warn "\n=== DEPOSITORY + CURRENCY ===\nCount: #{depository_filtered.count}\n#{depository_filtered.map { |a| "#{a.name}" }.join("\n")}\n"

    # Debug: check assets filter
    assets_filtered = depository_filtered.assets
    warn "\n=== DEPOSITORY + ASSETS ===\nCount: #{assets_filtered.count}\n#{assets_filtered.map { |a| "#{a.name} (classification=#{a.classification})" }.join("\n")}\n"

    cash_accts = generator.send(:cash_accounts)
    warn "\n=== FINAL CASH_ACCOUNTS ===\nCount: #{cash_accts.count}\n#{cash_accts.map { |a| "#{a.name} (liquidity=#{a.liquidity})" }.join("\n")}\n"

    insights = generator.generate

    assert_equal 1, insights.size, "Expected 1 insight but got #{insights.size}"
    assert_equal Money.new(100, "USD").format, insights.first.facts[:current_balance]
  end

  test "bills paid from a private account are left out of the projection" do
    private_series = @family.recurring_transactions.create!(
      name: "Private Gym", account: accounts(:connected), amount: 70, currency: "USD",
      expected_day_of_month: 15, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, status: "active", manual: true
    )
    private_series.recurring_occurrences.delete_all
    private_series.recurring_occurrences.create!(
      family: @family, original_due_on: Date.current + 2, due_on: Date.current + 2, currency: "USD"
    )

    entries = Insight::Generators::CashFlowWarningGenerator.new(@family).send(:upcoming_recurring_entries)

    assert_equal [ 60, 100, 100 ], entries.map(&:amount).map(&:to_i).sort
  end

  test "an inactive member does not hide an account from the projection" do
    users(:family_member).update_columns(active: false)
    accounts(:depository).update_columns(balance: 100)
    accounts(:connected).update_columns(balance: 50_000)

    assert_empty Insight::Generators::CashFlowWarningGenerator.new(@family).generate
  end
end
