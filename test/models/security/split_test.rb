require "test_helper"

class Security::SplitTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @security = securities(:aapl)
    @family = families(:dylan_family)
  end

  test "factor is new shares per old share" do
    assert_equal 4, build_split(ratio_from: 1, ratio_to: 4).factor
    assert_equal BigDecimal("0.1"), build_split(ratio_from: 10, ratio_to: 1).factor
  end

  test "rejects a ratio that changes nothing, a zero ratio and a future date" do
    assert_not build_split(ratio_from: 2, ratio_to: 2).valid?
    assert_not build_split(ratio_from: 0, ratio_to: 2).valid?
    assert_not build_split(date: 1.day.from_now.to_date).valid?
  end

  test "allows one provider split and one per family on the same day" do
    build_split.save!
    build_split(family: @family, source: "manual").save!

    assert_not build_split.valid?
    assert_not build_split(family: @family, source: "manual").valid?
    assert build_split(family: families(:empty), source: "manual").valid?
  end

  test "visible_to shows provider splits and the family's own" do
    provider = build_split.tap(&:save!)
    own = build_split(date: 2.days.ago.to_date, family: @family, source: "manual").tap(&:save!)
    build_split(date: 3.days.ago.to_date, family: families(:empty), source: "manual").save!

    assert_equal [ provider, own ].sort_by(&:id), Security::Split.visible_to(@family).sort_by(&:id)
  end

  test "recalculates holdings after a split is added, changed or removed" do
    split = build_split

    assert_enqueued_with(job: SecuritySplitAppliedJob) { split.save! }
    assert_enqueued_with(job: SecuritySplitAppliedJob) { split.update!(ratio_to: 3) }
    assert_enqueued_with(job: SecuritySplitAppliedJob) { split.destroy! }
  end

  private
    def build_split(date: 1.day.ago.to_date, ratio_from: 1, ratio_to: 4, family: nil, source: "provider")
      Security::Split.new(security: @security, date: date, ratio_from: ratio_from, ratio_to: ratio_to, family: family, source: source)
    end
end
