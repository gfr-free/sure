require "test_helper"

class Holding::SplitAdjustmentTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Splits",
      balance: 20000,
      cash_balance: 20000,
      currency: "USD",
      accountable: Investment.new
    )
    @security = Security.create!(ticker: "SPLT", name: "Split Corp")
    @split_date = 2.days.ago.to_date
    # Raw quotes, as a provider without split adjustment reports them.
    raw_prices = { 4 => 400, 3 => 400, 2 => 100, 1 => 100, 0 => 100 }
    raw_prices.each { |days, price| Security::Price.create!(security: @security, date: days.days.ago.to_date, price: price) }
    stub_price_provider(split_adjusted: false)
  end

  test "counts shares bought before a split on today's basis so value does not jump" do
    create_split(ratio_from: 1, ratio_to: 4)
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)

    calculated = forward

    4.downto(0).each do |days|
      holding = holding_on(calculated, days.days.ago.to_date)
      assert_equal 40, holding.qty, "qty #{days} days ago"
      assert_equal 100, holding.price, "price #{days} days ago"
      assert_equal 4000, holding.amount, "amount #{days} days ago"
      assert_equal 100, holding.cost_basis, "cost basis #{days} days ago"
    end
  end

  test "keeps value unchanged across the split date" do
    create_split(ratio_from: 1, ratio_to: 4)
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)

    calculated = forward

    assert_equal holding_on(calculated, @split_date - 1).amount, holding_on(calculated, @split_date).amount
  end

  test "trades on the split date are already on the new basis" do
    create_split(ratio_from: 1, ratio_to: 4)
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)
    create_trade(@security, qty: 5, date: @split_date, price: 100, account: @account)

    assert_equal 45, holding_on(forward, Date.current).qty
  end

  test "applies several splits cumulatively" do
    Security::Price.where(security: @security).delete_all
    { 4 => 600, 3 => 300, 2 => 300, 1 => 100, 0 => 100 }.each do |days, price|
      Security::Price.create!(security: @security, date: days.days.ago.to_date, price: price)
    end
    create_split(date: 3.days.ago.to_date, ratio_from: 1, ratio_to: 2)
    create_split(date: 1.day.ago.to_date, ratio_from: 1, ratio_to: 3)
    create_trade(@security, qty: 1, date: 4.days.ago.to_date, price: 600, account: @account)

    calculated = forward

    4.downto(0).each do |days|
      holding = holding_on(calculated, days.days.ago.to_date)
      assert_equal 6, holding.qty, "qty #{days} days ago"
      assert_equal 600, holding.amount, "amount #{days} days ago"
    end
  end

  test "handles a reverse split" do
    Security::Price.where(security: @security).delete_all
    { 4 => 10, 3 => 10, 2 => 100, 1 => 100, 0 => 100 }.each do |days, price|
      Security::Price.create!(security: @security, date: days.days.ago.to_date, price: price)
    end
    create_split(ratio_from: 10, ratio_to: 1)
    create_trade(@security, qty: 100, date: 4.days.ago.to_date, price: 10, account: @account)

    holding = holding_on(forward, 4.days.ago.to_date)

    assert_equal 10, holding.qty
    assert_equal 1000, holding.amount
    assert_equal 100, holding.cost_basis
  end

  test "uses split-adjusted provider prices as they are" do
    stub_price_provider(split_adjusted: true)
    Security::Price.where(security: @security, date: [ 4.days.ago.to_date, 3.days.ago.to_date ]).update_all(price: 100)
    create_split(ratio_from: 1, ratio_to: 4)
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)

    holding = holding_on(forward, 4.days.ago.to_date)

    assert_equal 40, holding.qty
    assert_equal 100, holding.price
    assert_equal 4000, holding.amount
  end

  test "skips a broker's zero-price split trade that a split record covers" do
    create_split(ratio_from: 1, ratio_to: 4)
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)
    create_broker_split_trade(qty: 30, date: @split_date + 1)

    assert_equal 40, holding_on(forward, Date.current).qty
  end

  test "keeps a broker's zero-price split trade when no split record exists" do
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)
    create_broker_split_trade(qty: 30, date: @split_date)

    calculated = forward

    assert_equal 10, holding_on(calculated, 3.days.ago.to_date).qty
    assert_equal 4000, holding_on(calculated, 3.days.ago.to_date).amount
    assert_equal 40, holding_on(calculated, Date.current).qty
    assert_equal 100, holding_on(calculated, Date.current).cost_basis
  end

  test "skips a zero-price buy a user entered for the split's extra shares" do
    create_split(ratio_from: 1, ratio_to: 4)
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)
    create_trade(@security, qty: 30, date: @split_date, price: 0, account: @account)

    assert_equal 40, holding_on(forward, Date.current).qty
  end

  test "a family's split replaces a provider split recorded a few days apart" do
    create_split(ratio_from: 1, ratio_to: 4)
    create_split(date: @split_date + 2, ratio_from: 1, ratio_to: 4, family: @family, source: "manual")
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)

    assert_equal 40, holding_on(forward, Date.current).qty
  end

  test "a family's own split replaces a provider split on the same day" do
    create_split(ratio_from: 1, ratio_to: 2)
    create_split(ratio_from: 1, ratio_to: 4, family: @family, source: "manual")
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)

    assert_equal 40, holding_on(forward, Date.current).qty
  end

  test "ignores another family's split" do
    create_split(ratio_from: 1, ratio_to: 4, family: families(:dylan_family), source: "manual")
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)

    assert_equal 10, holding_on(forward, Date.current).qty
  end

  test "reverse calculation walks back from today's post-split quantity" do
    create_split(ratio_from: 1, ratio_to: 4)
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)
    @account.holdings.create!(security: @security, date: Date.current, qty: 40, price: 100, amount: 4000, currency: "USD")

    snapshot = OpenStruct.new(to_h: { @security.id => 40 })
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate

    4.downto(0).each do |days|
      holding = holding_on(calculated, days.days.ago.to_date)
      assert_equal 40, holding.qty, "qty #{days} days ago"
      assert_equal 4000, holding.amount, "amount #{days} days ago"
      assert_equal 100, holding.cost_basis, "cost basis #{days} days ago"
    end
  end

  test "realized gain of a sale before a split uses the split-adjusted cost" do
    create_split(ratio_from: 1, ratio_to: 4)
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)
    sell = create_trade(@security, qty: -5, date: 3.days.ago.to_date, price: 440, account: @account).trade
    @account.holdings.create!(security: @security, date: 3.days.ago.to_date, qty: 20, price: 100, amount: 2000, currency: "USD", cost_basis: 100)

    gain = sell.realized_gain_loss

    assert_equal 2000, gain.previous.amount
    assert_equal 2200, gain.current.amount
  end

  test "realized gain of a sale after a split" do
    create_split(ratio_from: 1, ratio_to: 4)
    create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account)
    sell = create_trade(@security, qty: -20, date: 1.day.ago.to_date, price: 110, account: @account).trade
    @account.holdings.create!(security: @security, date: 1.day.ago.to_date, qty: 20, price: 100, amount: 2000, currency: "USD", cost_basis: 100)

    gain = sell.realized_gain_loss

    assert_equal 2000, gain.previous.amount
    assert_equal 2200, gain.current.amount
  end

  test "realized gain against a provider snapshot uses that day's basis" do
    create_split(ratio_from: 1, ratio_to: 4)
    sell = create_trade(@security, qty: -5, date: 3.days.ago.to_date, price: 440, account: @account).trade
    @account.holdings.create!(security: @security, date: 3.days.ago.to_date, qty: 5, price: 400, amount: 2000, currency: "USD", cost_basis: 400)
    Holding.any_instance.stubs(:account_provider_id).returns(SecureRandom.uuid)

    gain = sell.realized_gain_loss

    assert_equal 2000, gain.previous.amount
  end

  test "preloaded split factors match the per-trade lookup" do
    create_split(ratio_from: 1, ratio_to: 4)
    before = create_trade(@security, qty: -5, date: 3.days.ago.to_date, price: 440, account: @account).trade
    after = create_trade(@security, qty: -5, date: 1.day.ago.to_date, price: 110, account: @account).trade

    Trade.preload_split_factors([ before, after ])

    assert_equal 4, before.split_factor
    assert_equal 1, after.split_factor
  end

  test "unrealized gain of a buy before a split counts the shares it became" do
    create_split(ratio_from: 1, ratio_to: 4)
    buy = create_trade(@security, qty: 10, date: 4.days.ago.to_date, price: 400, account: @account).trade

    gain = buy.unrealized_gain_loss

    assert_equal 4000, gain.current.amount
    assert_equal 4000, gain.previous.amount
  end

  private
    def forward
      Holding::ForwardCalculator.new(@account).calculate
    end

    def holding_on(calculated, date)
      calculated.find { |holding| holding.security_id == @security.id && holding.date == date }
    end

    def create_split(ratio_from:, ratio_to:, date: @split_date, family: nil, source: "provider")
      Security::Split.create!(security: @security, date: date, ratio_from: ratio_from, ratio_to: ratio_to, family: family, source: source)
    end

    def create_broker_split_trade(qty:, date:)
      @account.entries.create!(
        name: "Split",
        date: date,
        amount: 0,
        currency: "USD",
        entryable: Trade.new(security: @security, qty: qty, price: 0, currency: "USD", investment_activity_label: "Other")
      )
    end

    def stub_price_provider(split_adjusted:)
      Security.any_instance.stubs(:price_data_provider).returns(stub(split_adjusted_prices?: split_adjusted))
    end
end
