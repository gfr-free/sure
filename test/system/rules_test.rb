require "application_system_test_case"

class RulesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "shows queued processed modified and blocked counts for recent rule runs" do
    rule = @user.family.rules.create!(
      name: "Whole Foods Testing",
      resource_type: "transaction",
      effective_date: 1.year.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods")
      ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: categories(:food_and_drink).id)
      ]
    )

    rule.rule_runs.create!(
      rule_name: rule.name,
      execution_type: "manual",
      status: "success",
      transactions_queued: 20,
      transactions_processed: 20,
      transactions_modified: 10,
      pending_jobs_count: 0,
      executed_at: Time.current
    )

    visit rules_path

    assert_selector "th", text: /queued\s+processed\s+modified\s+blocked/i
    assert_selector "td", text: "20 / 20 / 10 / 10"
  end

  test "reorders rules with the keyboard" do
    family = @user.family
    family.rules.destroy_all
    first = family.rules.create!(name: "First rule", resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    second = family.rules.create!(name: "Second rule", resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ])

    visit rules_path

    grip = find("[data-sortable-list-id='#{first.id}'] button[data-action*='handleKeyDown']")
    grip.send_keys(:enter)
    grip.send_keys(:arrow_down)
    grip.send_keys(:enter)

    assert_selector "[data-sortable-list-target='item']:first-child[data-sortable-list-id='#{second.id}']"
    # The order is saved by a fetch Capybara cannot wait on, so poll for it.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    sleep 0.05 until family.rules.ordered.pluck(:id) == [ second.id, first.id ] ||
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_equal [ second.id, first.id ], family.rules.ordered.pluck(:id)
  end

  test "rules page renders gracefully when a condition has an unsupported condition_type" do
    @user.update!(locale: "de")
    rule = @user.family.rules.create!(
      name: "Legacy bad rule",
      resource_type: "transaction",
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "x")
      ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: categories(:food_and_drink).id)
      ]
    )

    # Simulate a legacy row written before the inclusion validation existed.
    rule.conditions.first.update_columns(condition_type: "name")

    visit rules_path

    assert_selector "h3", text: "Legacy bad rule"
    assert_text "Nicht unterstützt (name)"
  end

  test "creates a transaction rule through the modal with dynamically added condition and action" do
    visit new_rule_path(resource_type: "transaction")

    within "dialog" do
      click_on "Add condition"
      find("[data-rules-target='conditionsList'] input[name$='[value]']").fill_in(with: "Coffee")
      click_on "Add action"
      click_on "Create Rule"
    end

    # A successful create lands on the confirmation dialog; before the
    # nested-attribute keys were numeric, the submit failed validation with
    # "must have at least one action" because strong params dropped the rows.
    assert_text "Confirm changes"

    rule = Rule.order(:created_at).last
    assert_equal "transaction_name", rule.conditions.first.condition_type
    assert_equal "Coffee", rule.conditions.first.value
    assert_equal "set_transaction_category", rule.actions.first.action_type
    assert rule.actions.first.value.present?
  end

  test "keeps a rule with long text inside a phone-width screen" do
    @user.family.rules.destroy_all
    rule = @user.family.rules.create!(
      name: "Gift card promotion savings plan with a very long descriptive name",
      resource_type: "transaction",
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "EXAMPLEMARKETPLACEPAYMENTSEUROPESARL")
      ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: categories(:food_and_drink).id)
      ]
    )

    page.current_window.resize_to(390, 844)
    visit rules_path

    row = find("##{ActionView::RecordIdentifier.dom_id(rule)}")
    viewport_width = page.evaluate_script("document.documentElement.clientWidth")

    row_right = row.native.rect.x + row.native.rect.width
    assert_operator row_right, :<=, viewport_width

    [ "h3", "span.truncate", "button[aria-haspopup]", "label" ].each do |selector|
      element = row.find(selector, match: :first, visible: :all)
      assert_operator element.native.rect.x + element.native.rect.width, :<=, row_right, "#{selector} runs past the rule row"
    end
    assert_operator row.find("h3").evaluate_script("this.scrollWidth - this.clientWidth"), :<=, 0, "rule name overflows"

    # On a phone the toggle and menu sit next to the rule name.
    name = row.find("h3").native.rect
    menu = row.find("button[aria-haspopup]").native.rect
    assert_operator menu.y, :<, name.y + name.height
    assert_operator menu.x, :>=, name.x + name.width

    new_rule = find("a", text: I18n.t("rules.index.new_rule"))
    assert_operator new_rule.native.rect.x + new_rule.native.rect.width, :<=, viewport_width
  end
end
