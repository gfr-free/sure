require "test_helper"

class Rule::AccountValueTest < ActiveSupport::TestCase
  setup do
    @rule = rules(:one)
    @hidden = accounts(:investment)
    @shared = accounts(:depository)
    Current.session = users(:family_member).sessions.create!
  end

  teardown do
    Current.reset
  end

  test "the transfer action and the account condition offer only accessible accounts" do
    [ Rule::ActionExecutor::SetAsTransferOrPayment.new(@rule), Rule::ConditionFilter::TransactionAccount.new(@rule) ].each do |chooser|
      ids = chooser.options.map(&:last)

      assert_includes ids, @shared.id
      assert_includes ids, accounts(:credit_card).id
      assert_not_includes ids, @hidden.id
    end
  end

  test "a stored transfer target the viewer can't access shows under a neutral label" do
    action = stored(@rule.actions, action_type: "set_as_transfer_or_payment", value: @hidden.id)

    assert_equal [ label, @hidden.id ], action.options.first
    assert_equal label, action.value_display
  end

  test "a stored account condition the viewer can't access shows under a neutral label" do
    condition = stored(@rule.conditions, condition_type: "transaction_account", operator: "=", value: @hidden.id)

    assert_equal [ label, @hidden.id ], condition.options.first
    assert_equal label, condition.value_display
  end

  test "an accessible stored account keeps its name and adds no placeholder" do
    action = Rule::Action.new(rule: @rule, action_type: "set_as_transfer_or_payment", value: @shared.id)

    assert_equal @shared.name, action.value_display
    assert_not_includes action.options.map(&:first), label
  end

  test "an account outside the family gets no placeholder" do
    other = families(:empty).accounts.create!(name: "Elsewhere", balance: 0, currency: "USD", accountable: Depository.new)
    action = stored(@rule.actions, action_type: "set_as_transfer_or_payment", value: other.id)

    assert_not_includes action.options.map(&:first), label
  end

  test "a member can't newly choose an account they can't access" do
    action = @rule.actions.build(action_type: "set_as_transfer_or_payment", value: @hidden.id)
    condition = @rule.conditions.build(condition_type: "transaction_account", operator: "=", value: @hidden.id)

    assert_not action.valid?
    assert_includes action.errors.details[:value], { error: :not_selectable }
    assert_not condition.valid?
    assert_includes condition.errors.details[:value], { error: :not_selectable }
    # Re-rendered like a missing account, so the form doesn't confirm the id exists.
    assert_not_includes action.options.map(&:first), label
    assert_not_includes condition.options.map(&:first), label
  end

  test "a missing account gets the same error as a hidden one" do
    action = @rule.actions.build(action_type: "set_as_transfer_or_payment", value: SecureRandom.uuid)

    assert_not action.valid?
    assert_includes action.errors.details[:value], { error: :not_selectable }
  end

  test "a stored hidden account survives saving unchanged, but can't be swapped for another" do
    action = stored(@rule.actions, action_type: "set_as_transfer_or_payment", value: @hidden.id)
    condition = stored(@rule.conditions, condition_type: "transaction_account", operator: "=", value: @hidden.id)

    assert action.reload.update(value: @hidden.id)
    assert condition.reload.update(value: @hidden.id)
    assert_not action.update(value: accounts(:loan).id)
  end

  test "jobs and imports without a signed-in user are not checked" do
    Current.reset

    assert @rule.actions.build(action_type: "set_as_transfer_or_payment", value: @hidden.id).valid?
  end

  private
    # Saved as a job or import would, without a signed-in user.
    def stored(association, **attributes)
      session = Current.session
      Current.reset
      association.create!(**attributes)
    ensure
      Current.session = session
    end

    def label
      I18n.t("rule.account_not_shared")
    end
end
