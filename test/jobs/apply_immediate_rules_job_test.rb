require "test_helper"

class ApplyImmediateRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Immediate test", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @changed = create_transaction(account: @account, name: "Whole Foods").transaction
    @untouched = create_transaction(account: @account, name: "Whole Foods").transaction
  end

  test "applies immediate rules only to the given transactions" do
    rule = create_rule("Groceries", category: @groceries, apply_immediately: true)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_equal @groceries, @changed.reload.category
    assert_nil @untouched.reload.category
    assert_equal [ "immediate" ], rule.rule_runs.pluck(:execution_type)
  end

  test "leaves nightly-only and inactive rules alone" do
    nightly = create_rule("Nightly", category: @groceries)
    inactive = create_rule("Inactive", category: @groceries, apply_immediately: true, active: false)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_nil @changed.reload.category
    assert_empty nightly.rule_runs
    assert_empty inactive.rule_runs
  end

  test "a nightly-only rule above holds the field back until the nightly run" do
    create_rule("Nightly", category: @dining)
    create_rule("Immediate", category: @groceries, apply_immediately: true)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])
    assert_nil @changed.reload.category

    ApplyRulesJob.perform_now(@family)
    assert_equal @dining, @changed.reload.category
  end

  test "keeps fields the person set themselves" do
    create_rule("Groceries", category: @groceries, apply_immediately: true)
    @changed.update!(category: @dining)
    @changed.lock_attr!(:category_id)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_equal @dining, @changed.reload.category
  end

  test "records no run for rules that match none of the transactions" do
    rule = create_rule("Other", match: "Hardware", category: @groceries, apply_immediately: true)

    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    assert_empty rule.rule_runs
  end

  test "refreshes open pages only when a rule changed something" do
    create_rule("Groceries", category: @groceries, apply_immediately: true)

    Family.any_instance.expects(:broadcast_refresh).once
    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])

    Family.any_instance.expects(:broadcast_refresh).never
    ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])
  end

  test "retries later when another rule run holds the family lock" do
    create_rule("Groceries", category: @groceries, apply_immediately: true)
    Rule::Runner.any_instance.stubs(:run).raises(Rule::Runner::LockBusy)

    assert_enqueued_with(job: ApplyImmediateRulesJob) do
      ApplyImmediateRulesJob.perform_now(@family, transaction_ids: [ @changed.id ])
    end
  end

  private
    def create_rule(name, category:, match: "Whole Foods", apply_immediately: false, active: true)
      @family.rules.create!(
        name: name,
        resource_type: "transaction",
        active: active,
        apply_immediately: apply_immediately,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: match) ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
      )
    end
end
