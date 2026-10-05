require "test_helper"

class LossPotTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
  end

  test "only securities and crypto accounts hold pots, one per kind" do
    assert @account.loss_pots.create(kind: "stocks").persisted?
    assert_not @account.loss_pots.build(kind: "stocks").valid?
    assert_not @account.loss_pots.build(kind: "options").valid?
    assert_not accounts(:depository).loss_pots.build(kind: "general").valid?
    assert accounts(:crypto).loss_pots.build(kind: "general").valid?
  end

  test "the opening balance is the latest entry up to the date, if it still counts" do
    pot = @account.loss_pots.create!(kind: "general")
    pot.snapshots.create!(date: Date.new(2024, 12, 31), amount: 500)
    pot.snapshots.create!(date: Date.new(2025, 12, 31), amount: 300)
    pot.snapshots.create!(date: Date.new(2026, 6, 30), amount: 100)

    assert_equal 300, pot.opening_for(2026, as_of: Date.new(2026, 5, 1)).amount
    assert_equal 100, pot.opening_for(2026, as_of: Date.new(2026, 7, 1)).amount
    assert_nil pot.opening_for(2024, as_of: Date.new(2024, 12, 30))

    pot.update!(carry_forward: false)
    assert_nil pot.opening_for(2026, as_of: Date.new(2026, 5, 1))
    assert_equal 100, pot.opening_for(2026, as_of: Date.new(2026, 7, 1)).amount
  end

  test "balances cannot be negative" do
    pot = @account.loss_pots.create!(kind: "general")

    assert_not pot.snapshots.build(date: Date.current, amount: -1).valid?
  end

  test "saving the account form only writes balances that changed" do
    stocks = @account.loss_pots.create!(kind: "stocks", carry_forward: false)
    stocks.snapshots.create!(date: Date.new(2025, 12, 31), amount: 100)
    @account.loss_pots.create!(kind: "general").snapshots.create!(date: Date.new(2026, 6, 30), amount: 200)
    @account.reload

    # The form shows both latest amounts and the newest date; nothing edited.
    @account.update!(loss_pot_stocks_amount: "100", loss_pot_general_amount: "200",
                     loss_pot_as_of: "2026-06-30", loss_pot_carry_forward: "0")

    assert_equal [ Date.new(2025, 12, 31) ], stocks.snapshots.reload.map(&:date)
    assert_equal [ false, true ], @account.loss_pots.reload.sort_by(&:kind).reverse.map(&:carry_forward)

    @account.reload.update!(loss_pot_stocks_amount: "80", loss_pot_general_amount: "200", loss_pot_as_of: "2026-06-30")

    assert_equal [ 100, 80 ], stocks.snapshots.reload.map(&:amount)
    assert_equal 1, @account.loss_pot("general").snapshots.count
  end

end
