require "test_helper"

# The balance sheet caches per member. Its keys must change whenever the
# member's shares change, or a revoked account keeps showing in the totals.
class BalanceSheet::AccountShareCacheKeyTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @member = users(:family_member)
    @period = Period.last_30_days
  end

  test "revoking a share that is not the newest changes the cache keys" do
    account_shares(:credit_card_shared_with_member).touch
    before = cache_keys

    account_shares(:depository_shared_with_member).destroy!

    before.zip(cache_keys).each { |old_key, new_key| assert_not_equal old_key, new_key }
  end

  test "a second share change within the same second changes the cache keys" do
    share = account_shares(:depository_shared_with_member)

    freeze_time do
      share.update!(include_in_finances: true, updated_at: Time.current.change(usec: 100))
      before = cache_keys

      share.update!(include_in_finances: false, updated_at: Time.current.change(usec: 900))

      before.zip(cache_keys).each { |old_key, new_key| assert_not_equal old_key, new_key }
    end
  end

  test "replacing a share with an older one changes the cache keys" do
    newest = account_shares(:depository_shared_with_member)
    newest.touch
    before = cache_keys

    other = account_shares(:credit_card_shared_with_member)
    other.destroy!
    AccountShare.create!(account: accounts(:investment), user: @member, permission: "read_only",
                         created_at: other.created_at, updated_at: other.updated_at)

    before.zip(cache_keys).each { |old_key, new_key| assert_not_equal old_key, new_key }
  end

  private
    def cache_keys
      family = @family.reload
      [
        BalanceSheet::NetWorthSeriesBuilder.new(family, user: @member).send(:cache_key, @period),
        BalanceSheet::NetWorthBreakdownSeriesBuilder.new(family, user: @member).send(:cache_key, @period),
        BalanceSheet::AccountTotals.new(family, user: @member, sync_status_monitor: nil).send(:cache_key)
      ]
    end
end
