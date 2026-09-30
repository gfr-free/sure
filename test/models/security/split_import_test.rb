require "test_helper"

class Security::SplitImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @security = securities(:aapl)
    @provider = mock
    @provider.stubs(:respond_to?).with(:fetch_security_splits).returns(true)
    @security.stubs(:price_data_provider).returns(@provider)
  end

  test "stores provider splits once and records the check" do
    @provider.expects(:fetch_security_splits).returns(successful_response([ provider_split(Date.new(2024, 6, 10), 1, 10) ]))

    assert_difference -> { @security.splits.count }, 1 do
      assert_equal 1, @security.import_provider_splits(start_date: Date.new(2024, 1, 1))
    end

    split = @security.splits.sole
    assert_nil split.family_id
    assert_equal "provider", split.source
    assert_equal 10, split.factor
    assert @security.reload.splits_checked_at.present?
  end

  test "recalculates once for a batch of new splits" do
    @provider.expects(:fetch_security_splits).returns(successful_response([
      provider_split(Date.new(2021, 3, 1), 1, 2),
      provider_split(Date.new(2024, 6, 10), 1, 10)
    ]))

    assert_enqueued_jobs 1, only: SecuritySplitAppliedJob do
      @security.import_provider_splits(start_date: Date.new(2020, 1, 1))
    end
  end

  test "moves a provider split whose date the provider corrected" do
    @security.splits.create!(date: Date.new(2024, 6, 7), ratio_from: 1, ratio_to: 10, source: "provider")
    @provider.expects(:fetch_security_splits).returns(successful_response([ provider_split(Date.new(2024, 6, 10), 1, 10) ]))

    @security.import_provider_splits(start_date: Date.new(2024, 1, 1))

    assert_equal [ Date.new(2024, 6, 10) ], @security.splits.pluck(:date)
  end

  test "asks from the first trade even when the caller asks for recent days" do
    account = families(:empty).accounts.create!(name: "Old trades", balance: 0, currency: "USD", accountable: Investment.new)
    account.entries.create!(name: "Buy", date: Date.new(2018, 5, 2), amount: 100, currency: "USD",
                            entryable: Trade.new(security: @security, qty: 1, price: 100, currency: "USD", investment_activity_label: "Buy"))
    @provider.expects(:fetch_security_splits).with(has_entries(start_date: Date.new(2018, 5, 2))).returns(successful_response([]))

    @security.import_provider_splits(start_date: 31.days.ago.to_date)
  end

  test "asks the provider at most once a day" do
    @security.update!(splits_checked_at: 1.hour.ago)
    @provider.expects(:fetch_security_splits).never

    assert_equal 0, @security.import_provider_splits(start_date: Date.new(2024, 1, 1))
  end

  test "updates a provider split whose ratio changed and leaves unchanged ones alone" do
    @security.splits.create!(date: Date.new(2024, 6, 10), ratio_from: 1, ratio_to: 5, source: "provider")
    @security.splits.create!(date: Date.new(2022, 1, 3), ratio_from: 1, ratio_to: 2, source: "provider")
    @provider.expects(:fetch_security_splits).returns(successful_response([
      provider_split(Date.new(2022, 1, 3), 1, 2),
      provider_split(Date.new(2024, 6, 10), 1, 10)
    ]))

    assert_equal 1, @security.import_provider_splits(start_date: Date.new(2020, 1, 1))
    assert_equal 10, @security.splits.find_by(date: Date.new(2024, 6, 10)).factor
  end

  test "does not touch a family's own split on the same day" do
    @security.splits.create!(date: Date.new(2024, 6, 10), ratio_from: 1, ratio_to: 4, source: "manual", family: families(:dylan_family))
    @provider.expects(:fetch_security_splits).returns(successful_response([ provider_split(Date.new(2024, 6, 10), 1, 10) ]))

    @security.import_provider_splits(start_date: Date.new(2024, 1, 1))

    assert_equal 4, @security.splits.find_by(family: families(:dylan_family)).factor
    assert_equal 10, @security.splits.find_by(family_id: nil).factor
  end

  test "logs a failed fetch and tries again next time" do
    @provider.expects(:fetch_security_splits).returns(failed_response("rate limited"))
    DebugLogEntry.expects(:capture).with(has_entries(category: "security_splits_fetch", level: "warn"))

    assert_equal 0, @security.import_provider_splits(start_date: Date.new(2024, 1, 1))
    assert_nil @security.reload.splits_checked_at
  end

  test "skips providers without split data" do
    @provider.stubs(:respond_to?).with(:fetch_security_splits).returns(false)

    assert_equal 0, @security.import_provider_splits(start_date: Date.new(2024, 1, 1))
  end

  private
    def provider_split(date, ratio_from, ratio_to)
      Provider::SecurityConcept::Split.new(symbol: @security.ticker, date: date, ratio_from: ratio_from, ratio_to: ratio_to)
    end

    def successful_response(data)
      Provider::Response.new(success?: true, data: data, error: nil)
    end

    def failed_response(message)
      Provider::Response.new(success?: false, data: nil, error: Provider::Error.new(message))
    end
end
