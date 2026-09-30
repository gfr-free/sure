require "test_helper"

class HoldingSplitsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = accounts(:investment)
    @holding = @account.holdings.first
    @security = @holding.security
  end

  test "adds a split for the current family only" do
    assert_difference -> { @security.splits.count }, 1 do
      post holding_splits_path(@holding), params: { security_split: { date: 3.days.ago.to_date, ratio_from: 1, ratio_to: 4 } }
    end

    split = @security.splits.order(:created_at).last
    assert_equal @account.family_id, split.family_id
    assert_equal "manual", split.source
    assert_redirected_to account_path(@account, tab: "holdings")
  end

  test "rejects an invalid split" do
    assert_no_difference -> { @security.splits.count } do
      post holding_splits_path(@holding), params: { security_split: { date: 3.days.ago.to_date, ratio_from: 2, ratio_to: 2 } }
    end

    assert flash[:alert].present?
  end

  test "deletes the family's own split" do
    split = @security.splits.create!(date: 3.days.ago.to_date, ratio_from: 1, ratio_to: 4, source: "manual", family: @account.family)

    assert_difference -> { @security.splits.count }, -1 do
      delete holding_split_path(@holding, split)
    end
  end

  test "cannot delete a provider split or another family's split" do
    provider_split = @security.splits.create!(date: 3.days.ago.to_date, ratio_from: 1, ratio_to: 4, source: "provider")
    foreign_split = @security.splits.create!(date: 4.days.ago.to_date, ratio_from: 1, ratio_to: 2, source: "manual", family: families(:empty))

    [ provider_split, foreign_split ].each do |split|
      delete holding_split_path(@holding, split)
      assert_response :not_found
    end

    assert_equal 2, @security.splits.count
  end

  test "shows the family's splits in the holding drawer" do
    @security.splits.create!(date: 3.days.ago.to_date, ratio_from: 1, ratio_to: 4, source: "manual", family: @account.family)
    @security.splits.create!(date: 4.days.ago.to_date, ratio_from: 1, ratio_to: 7, source: "manual", family: families(:empty))

    get holding_path(@holding)

    assert_response :success
    assert_select "li", text: /1 : 4/
    assert_select "li", text: /1 : 7/, count: 0
  end

  test "refuses a split when the user cannot edit every family account holding the security" do
    Security::Split.stubs(:manageable_by?).returns(false)

    assert_no_difference -> { @security.splits.count } do
      post holding_splits_path(@holding), params: { security_split: { date: 3.days.ago.to_date, ratio_from: 1, ratio_to: 4 } }
    end

    assert flash[:alert].present?
  end

  test "hides the split form from users who cannot manage splits" do
    Security::Split.stubs(:manageable_by?).returns(false)

    get holding_path(@holding)

    assert_response :success
    assert_select "input[name='security_split[ratio_to]']", count: 0
  end
end
