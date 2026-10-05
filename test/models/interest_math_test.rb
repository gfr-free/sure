require "test_helper"

class InterestMathTest < ActiveSupport::TestCase
  test "the day count follows the currency" do
    assert_equal "thirty_360", InterestMath.day_count_for("EUR")
    assert_equal "act_365", InterestMath.day_count_for("USD")
  end

  test "30E/360 counts every month as 30 days and the year as 360" do
    weight = ->(from, to) { (from..to).sum { |date| InterestMath.day_weight(date, "thirty_360") } }

    assert_equal 30, weight.call(Date.new(2026, 1, 1), Date.new(2026, 1, 31))
    assert_equal 30, weight.call(Date.new(2026, 2, 1), Date.new(2026, 2, 28))
    assert_equal 30, weight.call(Date.new(2028, 2, 1), Date.new(2028, 2, 29))
    assert_equal 360, weight.call(Date.new(2026, 1, 1), Date.new(2026, 12, 31))
  end

  test "accrues day by day on the balance and the rate of each day" do
    january = { from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 31), balance_on: ->(_date) { 10_000 } }

    euro = InterestMath.accrue(**january, day_count: "thirty_360", rate_on: ->(_date, _balance) { 3 })
    dollar = InterestMath.accrue(**january, day_count: "act_365", rate_on: ->(_date, _balance) { 3 })

    assert_in_delta 25, euro.to_f, 1e-9
    assert_in_delta 25.48, dollar.to_f, 0.005
  end

  test "no rate and no balance accrue nothing" do
    assert_equal 0, InterestMath.daily_interest(1000, nil, Date.new(2026, 1, 1), "act_365")
    assert_equal 0, InterestMath.daily_interest(0, 3, Date.new(2026, 1, 1), "act_365")
  end
end
