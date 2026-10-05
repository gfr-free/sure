require "test_helper"

class RuleTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @whole_foods_merchant = @family.merchants.create!(name: "Whole Foods", type: "FamilyMerchant")
    @groceries_category = @family.categories.create!(name: "Groceries")
  end

  test "basic rule" do
    transaction_entry = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply

    transaction_entry.reload

    assert_equal @groceries_category, transaction_entry.transaction.category
  end

  test "compound rule" do
    transaction_entry1 = create_transaction(date: Date.current, amount: 50, account: @account, merchant: @whole_foods_merchant)
    transaction_entry2 = create_transaction(date: Date.current, amount: 100, account: @account, merchant: @whole_foods_merchant)

    # Assign "Groceries" to transactions with a merchant of "Whole Foods" and an amount greater than $60
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [
          Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id),
          Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: 60)
        ])
      ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply

    transaction_entry1.reload
    transaction_entry2.reload

    assert_nil transaction_entry1.transaction.category
    assert_equal @groceries_category, transaction_entry2.transaction.category
  end

  test "exclude transaction rule" do
    transaction_entry = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)

    assert_not transaction_entry.excluded, "Transaction should not be excluded initially"

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    rule.apply

    transaction_entry.reload

    assert transaction_entry.excluded, "Transaction should be excluded after rule applies"
  end

  test "exclude transaction rule respects attribute locks" do
    transaction_entry = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)
    transaction_entry.lock_attr!(:excluded)

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    rule.apply

    transaction_entry.reload

    assert_not transaction_entry.excluded, "Transaction should not be excluded when attribute is locked"
  end

  test "transaction name rules normalize whitespace in comparisons" do
    transaction_entry = create_transaction(
      date: Date.current,
      account: @account,
      name: "Company  -   Mobile",
      amount: 80
    )

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Company - Mobile") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    assert_equal 1, rule.affected_resource_count

    rule.apply
    transaction_entry.reload

    assert_equal @groceries_category, transaction_entry.transaction.category
  end

  # Artificial limitation put in place to prevent users from creating overly complex rules
  # Rules should be shallow and wide
  test "no nested compound conditions" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ],
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [
          Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [
            Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Starbucks")
          ])
        ])
      ]
    )

    assert_not rule.valid?
    assert_equal [ "Compound conditions cannot be nested" ], rule.errors.full_messages
  end

  test "displayed_condition falls back to next valid condition when first compound condition is empty" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ],
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and"),
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "starbucks")
      ]
    )

    displayed_condition = rule.displayed_condition

    assert_not_nil displayed_condition
    assert_equal "transaction_name", displayed_condition.condition_type
    assert_equal "like", displayed_condition.operator
    assert_equal "starbucks", displayed_condition.value
  end

  test "additional_displayable_conditions_count ignores empty compound conditions" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ],
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and"),
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "first"),
        Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: 100)
      ]
    )

    assert_equal 1, rule.additional_displayable_conditions_count
  end

  test "rule matching on transaction details" do
    # Create PayPal transaction with underlying merchant in details
    paypal_entry = create_transaction(
      date: Date.current,
      account: @account,
      name: "PayPal",
      amount: 50
    )
    paypal_entry.transaction.update!(
      extra: {
        "simplefin" => {
          "payee" => "Whole Foods via PayPal",
          "description" => "Grocery shopping"
        }
      }
    )

    # Create another PayPal transaction with different underlying merchant
    paypal_entry2 = create_transaction(
      date: Date.current,
      account: @account,
      name: "PayPal",
      amount: 100
    )
    paypal_entry2.transaction.update!(
      extra: {
        "simplefin" => {
          "payee" => "Amazon via PayPal"
        }
      }
    )

    # Rule to categorize PayPal transactions containing "Whole Foods" in details
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_details", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply

    paypal_entry.reload
    paypal_entry2.reload

    assert_equal @groceries_category, paypal_entry.transaction.category, "PayPal transaction with 'Whole Foods' in details should be categorized"
    assert_nil paypal_entry2.transaction.category, "PayPal transaction without 'Whole Foods' in details should not be categorized"
  end

  test "rule matching on transaction notes" do
    # Create transaction with notes
    transaction_entry = create_transaction(
      date: Date.current,
      account: @account,
      name: "Expense",
      amount: 50
    )
    transaction_entry.update!(notes: "Business lunch with client")

    # Create another transaction without relevant notes
    transaction_entry2 = create_transaction(
      date: Date.current,
      account: @account,
      name: "Expense",
      amount: 100
    )
    transaction_entry2.update!(notes: "Personal expense")

    # Rule to categorize transactions with "business" in notes
    business_category = @family.categories.create!(name: "Business")
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_notes", operator: "like", value: "business") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: business_category.id) ]
    )

    rule.apply

    transaction_entry.reload
    transaction_entry2.reload

    assert_equal business_category, transaction_entry.transaction.category, "Transaction with 'business' in notes should be categorized"
    assert_nil transaction_entry2.transaction.category, "Transaction without 'business' in notes should not be categorized"
  end

  test "total_affected_resource_count deduplicates overlapping rules" do
    # Create transactions
    transaction_entry1 = create_transaction(date: Date.current, account: @account, name: "Whole Foods", amount: 50)
    transaction_entry2 = create_transaction(date: Date.current, account: @account, name: "Whole Foods", amount: 100)
    transaction_entry3 = create_transaction(date: Date.current, account: @account, name: "Target", amount: 75)

    # Rule 1: Match transactions with name "Whole Foods" (matches txn 1 and 2)
    rule1 = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    # Rule 2: Match transactions with amount > 60 (matches txn 2 and 3)
    rule2 = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: 60) ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    # Rule 1 affects 2 transactions, Rule 2 affects 2 transactions
    # But transaction_entry2 is matched by both, so total unique should be 3
    assert_equal 2, rule1.affected_resource_count
    assert_equal 2, rule2.affected_resource_count
    assert_equal 3, Rule.total_affected_resource_count([ rule1, rule2 ])
  end

  test "total_affected_resource_count returns zero for empty rules" do
    assert_equal 0, Rule.total_affected_resource_count([])
  end

  test "rule matching on transaction account" do
    # Create a second account
    other_account = @family.accounts.create!(
      name: "Other account",
      balance: 500,
      currency: "USD",
      accountable: Depository.new
    )

    # Transaction on the target account
    transaction_entry1 = create_transaction(
      date: Date.current,
      account: @account,
      amount: 50
    )

    # Transaction on another account
    transaction_entry2 = create_transaction(
      date: Date.current,
      account: other_account,
      amount: 75
    )

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_account",
          operator: "=",
          value: @account.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    rule.apply

    transaction_entry1.reload
    transaction_entry2.reload

    assert_equal @groceries_category, transaction_entry1.transaction.category,
      "Transaction on selected account should be categorized"

    assert_nil transaction_entry2.transaction.category,
      "Transaction on other account should not be categorized"
  end

  test "new rules are added at the end of the run order" do
    first = create_exclude_rule
    second = create_exclude_rule

    assert_equal first.position + 1, second.position
    assert_equal [ first, second ], @family.rules.ordered.to_a
  end

  test "update_positions! sets the order of all rules of the family" do
    first = create_exclude_rule
    second = create_exclude_rule

    Rule.update_positions!(@family, [ second.id, first.id ])

    assert_equal [ second, first ], @family.rules.ordered.to_a
  end

  test "update_positions! rejects foreign and incomplete id lists" do
    first = create_exclude_rule
    second = create_exclude_rule
    foreign = rules(:one)

    assert_raises(ArgumentError) { Rule.update_positions!(@family, [ first.id, second.id, foreign.id ]) }
    assert_raises(ArgumentError) { Rule.update_positions!(@family, [ first.id ]) }
    assert_raises(ArgumentError) { Rule.update_positions!(@family, [ first.id, first.id ]) }
    assert_equal 1, foreign.reload.position
    assert_equal [ first, second ], @family.rules.ordered.to_a
  end

  test "apply_immediately_later enqueues only when the family has active immediate rules" do
    transaction = create_transaction(account: @account, name: "Whole Foods").transaction
    create_category_rule("Nightly")
    create_category_rule("Paused", apply_immediately: true, active: false)

    assert_no_enqueued_jobs(only: ApplyImmediateRulesJob) do
      Rule.apply_immediately_later(@family, transaction.id)
    end

    create_category_rule("Immediate", apply_immediately: true)

    assert_enqueued_with(job: ApplyImmediateRulesJob, args: [ @family, { transaction_ids: [ transaction.id ] } ]) do
      Rule.apply_immediately_later(@family, [ transaction.id, transaction.id, nil ])
    end
    assert_no_enqueued_jobs(only: ApplyImmediateRulesJob) do
      Rule.apply_immediately_later(@family, [])
    end
  end

  test "apply_immediately_later does not raise when the job cannot be enqueued" do
    transaction = create_transaction(account: @account, name: "Whole Foods").transaction
    create_category_rule("Immediate", apply_immediately: true)
    ApplyImmediateRulesJob.stubs(:perform_later).raises(RuntimeError, "queue down")

    assert_nil Rule.apply_immediately_later(@family, transaction.id)
  end

  test "immediate_conflicts lists nightly rules above that set the same field on shared transactions" do
    create_transaction(account: @account, name: "Whole Foods")
    nightly = create_category_rule("Nightly")
    create_category_rule("Other field", match: "Whole", action: Rule::Action.new(action_type: "set_transaction_name", value: "WF"))
    create_category_rule("No overlap", match: "Hardware")
    create_category_rule("Immediate above", apply_immediately: true)
    immediate = create_category_rule("Immediate", apply_immediately: true)
    below = create_category_rule("Below")

    assert_equal [ nightly ], immediate.immediate_conflicts
    assert_equal [ nightly ], Rule.immediate_conflicts(@family.rules.ordered)[immediate.id]
    assert_empty below.immediate_conflicts
  end

  test "immediate_conflicts includes a nightly stop-processing rule above" do
    create_transaction(account: @account, name: "Whole Foods")
    stopper = create_category_rule("Stopper", action: Rule::Action.new(action_type: "set_transaction_name", value: "WF"), stop_processing: true)
    immediate = create_category_rule("Immediate", apply_immediately: true)

    assert_equal [ stopper ], immediate.immediate_conflicts
  end

  test "move_above! puts the rule directly above the other one" do
    first = create_exclude_rule
    second = create_exclude_rule
    third = create_exclude_rule

    third.move_above!(second)
    assert_equal [ first, third, second ], @family.rules.ordered.to_a

    third.move_above!(third)
    assert_equal [ first, third, second ], @family.rules.ordered.to_a
  end

  test "pending_field_hints names the nightly rule that will fill an empty field" do
    transaction = create_transaction(account: @account, name: "Whole Foods").transaction
    nightly = create_category_rule("Nightly")
    create_category_rule("Immediate", apply_immediately: true)

    assert_equal({ category_id: nightly }, Rule.pending_field_hints(transaction))

    transaction.lock_attr!(:category_id)
    assert_empty Rule.pending_field_hints(transaction.reload)
  end

  test "pending_field_hints is empty without immediate rules or when an immediate rule wins" do
    transaction = create_transaction(account: @account, name: "Whole Foods").transaction
    create_category_rule("Nightly", match: "Whole")

    assert_empty Rule.pending_field_hints(transaction)

    immediate = create_category_rule("Immediate", apply_immediately: true)
    immediate.move_above!(@family.rules.find_by(name: "Nightly"))

    assert_empty Rule.pending_field_hints(transaction)
  end

  private
    def create_exclude_rule
      @family.rules.create!(resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end

    def create_category_rule(name, match: "Whole Foods", apply_immediately: false, active: true, stop_processing: false, action: nil)
      @family.rules.create!(
        name: name,
        resource_type: "transaction",
        active: active,
        apply_immediately: apply_immediately,
        stop_processing: stop_processing,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: match) ],
        actions: [ action || Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
      )
    end
end
