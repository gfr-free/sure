require "test_helper"

class SecuritySplitAppliedJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @security = Security.create!(ticker: "SPLJ", name: "Split Job Corp")
    @own_account = families(:dylan_family).accounts.create!(name: "Own", balance: 0, currency: "USD", accountable: Investment.new)
    @other_account = families(:empty).accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Investment.new)
    create_trade(@security, qty: 1, date: 10.days.ago.to_date, price: 100, account: @own_account)
    create_trade(@security, qty: 1, date: 10.days.ago.to_date, price: 100, account: @other_account)
    @security.stubs(:price_data_provider).returns(nil)
    Security.stubs(:find_by).with(id: @security.id).returns(@security)
  end

  test "a provider split recalculates every account holding the security" do
    synced = []
    Account.any_instance.stubs(:sync_later).with { synced << true }

    SecuritySplitAppliedJob.perform_now(security_id: @security.id, family_id: nil, split_date: 5.days.ago.to_date.iso8601)

    assert_equal 2, synced.size
  end

  test "a family's own split recalculates only that family's accounts" do
    Account.any_instance.expects(:sync_later).once

    SecuritySplitAppliedJob.perform_now(security_id: @security.id, family_id: families(:dylan_family).id, split_date: 5.days.ago.to_date.iso8601)
  end

  test "fetches split-adjusted price history again up to the split date" do
    Security::Price.create!(security: @security, date: 10.days.ago.to_date, price: 400)
    @security.stubs(:price_data_provider).returns(stub(split_adjusted_prices?: true))
    Account.any_instance.stubs(:sync_later)

    @security.expects(:import_provider_prices).with(start_date: 10.days.ago.to_date, end_date: 6.days.ago.to_date, clear_cache: true)

    SecuritySplitAppliedJob.perform_now(security_id: @security.id, family_id: nil, split_date: 5.days.ago.to_date.iso8601)
  end

  test "leaves raw price history alone" do
    Security::Price.create!(security: @security, date: 10.days.ago.to_date, price: 400)
    @security.stubs(:price_data_provider).returns(stub(split_adjusted_prices?: false))
    Account.any_instance.stubs(:sync_later)

    @security.expects(:import_provider_prices).never

    SecuritySplitAppliedJob.perform_now(security_id: @security.id, family_id: nil, split_date: 5.days.ago.to_date.iso8601)
  end

  test "retries an account whose sync is already running" do
    @own_account.syncs.create!(status: "syncing")
    synced = []
    Account.any_instance.stubs(:sync_later).with { synced << true }

    assert_enqueued_with(job: SecuritySplitAppliedJob, args: [ {
      security_id: @security.id,
      family_id: nil,
      split_date: 5.days.ago.to_date.iso8601,
      account_ids: [ @own_account.id ],
      attempts_remaining: SecuritySplitAppliedJob::MAX_ATTEMPTS - 1
    } ]) do
      SecuritySplitAppliedJob.perform_now(security_id: @security.id, family_id: nil, split_date: 5.days.ago.to_date.iso8601)
    end

    assert_equal 1, synced.size
  end
end
