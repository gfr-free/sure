require "test_helper"

class Insight::Generators::IdleCashGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    Entry.delete_all
  end

  # The feed is shared by the whole family: `connected` is private to
  # family_admin, so its name and balance must not reach the feed.
  test "a private idle cash account is not reported" do
    accounts(:connected).update_columns(balance: 50_000)

    insights = Insight::Generators::IdleCashGenerator.new(@family).generate

    assert_not_includes insights.map { |i| i.metadata[:account_id] }, accounts(:connected).id
    assert insights.none? { |i| i.title.include?(accounts(:connected).name) }
  end

  test "a shared idle cash account is still reported" do
    accounts(:depository).update_columns(balance: 50_000)

    insights = Insight::Generators::IdleCashGenerator.new(@family).generate

    assert_includes insights.map { |i| i.metadata[:account_id] }, accounts(:depository).id
  end
end
