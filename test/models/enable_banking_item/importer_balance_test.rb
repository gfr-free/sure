require "test_helper"
require "ostruct"

class EnableBankingItem::ImporterBalanceTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "CGD PT",
      country_code: "PT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      status: :good
    )

    @enable_banking_account = @enable_banking_item.enable_banking_accounts.create!(
      name: "CGD Current",
      uid: "identification_hash_1",
      account_id: "11111111-1111-1111-1111-111111111111",
      currency: "EUR",
      current_balance: 123.45,
      account_status: "active",
      provider: "enable_banking"
    )

    @mock_provider = OpenStruct.new
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
  end

  test "FRESHNESS_BALANCE_TYPES only lists normalized spellings that BALANCE_TYPE_PRIORITY itself accepts" do
    normalized_priority_types = EnableBankingItem::Importer::BALANCE_TYPE_PRIORITY.map { |type| type.delete("_-").downcase }

    assert_empty EnableBankingItem::Importer::FRESHNESS_BALANCE_TYPES - normalized_priority_types,
      "FRESHNESS_BALANCE_TYPES drifted from BALANCE_TYPE_PRIORITY - every accepted spelling here must also be recognized there"
  end

  test "PERIOD_BOUNDARY_TYPES lists both the ISO code and descriptive spelling for OPBD and PRCD" do
    assert_equal %w[opbd openingbooked prcd previouslyclosedbooked].sort, EnableBankingItem::Importer::PERIOD_BOUNDARY_TYPES.sort,
      "PERIOD_BOUNDARY_TYPES must cover both spellings for OPBD/PRCD, mirroring FRESHNESS_BALANCE_TYPES, or the freshness guard silently skips ASPSPs that send the descriptive spelling"
  end

  test "fetch_and_update_balance prefers booked balance before available balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "ITAV",
          balance_amount: { amount: "1250.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "ITBD",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "DBIT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("-50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers opening/previously-closed booked balance over expected and available" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "CLAV",
          balance_amount: { amount: "2000.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "XPCD",
          balance_amount: { amount: "1500.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "PRCD",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "DBIT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("-50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers opening booked balance over previously-closed booked balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "PRCD",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "openingBooked",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("75.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers a materially newer expected balance over a stale opening booked balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          reference_date: "2026-09-01",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "XPCD",
          reference_date: "2026-09-25",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("75.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance keeps the period-boundary balance when reference_date is missing" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "XPCD",
          reference_date: "2026-09-25",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers a materially newer descriptive-spelling balance over a stale opening booked balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          reference_date: "2026-09-01",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "closingAvailable",
          reference_date: "2026-09-25",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("75.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance prefers a materially newer balance over a stale descriptive-spelling opening booked balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "openingBooked",
          reference_date: "2026-09-01",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "closingAvailable",
          reference_date: "2026-09-25",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("75.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance ignores a newer reference_date on a non-accounting balance type" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          reference_date: "2026-09-01",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "FWAV",
          reference_date: "2026-09-25",
          balance_amount: { amount: "999.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance keeps the period-boundary balance when it is not older than other balances" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "OPBD",
          reference_date: "2026-09-25",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "XPCD",
          reference_date: "2026-09-01",
          balance_amount: { amount: "75.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance falls back to the first balance when only unprioritized types are present" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "FWAV",
          balance_amount: { amount: "10.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "OTHR",
          balance_amount: { amount: "999.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("10.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance handles descriptive booked balance types" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "interimAvailable",
          balance_amount: { amount: "2000.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "closingBooked",
          balance_amount: { amount: "321.09", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("321.09"), @enable_banking_account.reload.current_balance
  end

  test "balance endpoint failure marks provider balance unavailable and creates sanitized debug log" do
    error = Provider::EnableBanking::EnableBankingError.new(
      "Bad request to Enable Banking API: {\"error\":\"BALANCES_UNAVAILABLE\"}",
      :bad_request,
      response_data: {
        error: "BALANCES_UNAVAILABLE",
        detail: { account_id: "sensitive_account_id_should_not_be_persisted" }
      }
    )

    @mock_provider.stubs(:get_account_balances).raises(error)

    assert_difference "DebugLogEntry.count", 1 do
      assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    assert_nil @enable_banking_account.reload.current_balance

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync_error", entry.category
    assert_equal "warn", entry.level
    assert_equal "enable_banking", entry.provider_key
    assert_equal "bad_request", entry.metadata["error_type"]
    assert_equal "BALANCES_UNAVAILABLE", entry.metadata.dig("provider_error", "error")
    assert_nil entry.metadata["response_data"]
    assert_nil entry.metadata.dig("provider_error", "account_id")
  end

  test "empty balance response marks provider balance unavailable" do
    @mock_provider.stubs(:get_account_balances).returns(balances: [])

    assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)
    assert_nil @enable_banking_account.reload.current_balance
  end

  test "unusable balance response marks provider balance unavailable" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "CLBD",
          balance_amount: { currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)
    assert_nil @enable_banking_account.reload.current_balance
  end

  test "import continues transaction sync when balance refresh fails" do
    depository = Depository.create!
    linked_account = Account.create!(
      family: @family,
      name: "CGD linked",
      balance: 123.45,
      cash_balance: 123.45,
      currency: "EUR",
      accountable: depository
    )
    AccountProvider.create!(account: linked_account, provider: @enable_banking_account)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.expects(:fetch_and_update_balance).with(@enable_banking_account).returns(false)
    @importer.expects(:fetch_and_store_transactions).with(@enable_banking_account).returns(
      success: true,
      transactions_count: 2
    )

    result = @importer.import

    assert result[:success]
    assert_equal 2, result[:transactions_imported]
    assert_equal 0, result[:transactions_failed]
    assert_equal 1, result[:balances_failed]
  end

  test "balance endpoint failure marks unsaved provider balance unavailable" do
    unsaved_account = EnableBankingAccount.new(
      enable_banking_item: @enable_banking_item,
      uid: "unsaved-account",
      current_balance: BigDecimal("123.45"),
      currency: "EUR"
    )

    unsaved_account.stubs(:api_account_id).returns("unsaved-account")

    error = Provider::EnableBanking::EnableBankingError.new(
      "Bad request to Enable Banking API",
      :bad_request,
      response_data: { error: "BALANCES_UNAVAILABLE" }
    )

    @mock_provider.stubs(:get_account_balances).raises(error)

    assert_nothing_raised do
      assert_not @importer.send(:fetch_and_update_balance, unsaved_account)
    end

    assert_nil unsaved_account.current_balance
  end

  test "import refreshes the balance after fetching transactions" do
    link_account(Depository.create!)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    order = sequence("balance after transactions")
    @importer.expects(:fetch_and_store_transactions).with(@enable_banking_account).returns(success: true, transactions_count: 0).in_sequence(order)
    @importer.expects(:fetch_and_update_balance).with(@enable_banking_account).returns(true).in_sequence(order)

    @importer.import
  end

  test "import still refreshes the balance when the transaction fetch raises" do
    link_account(Depository.create!)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.stubs(:fetch_and_store_transactions).raises(StandardError, "boom")
    @importer.expects(:fetch_and_update_balance).with(@enable_banking_account).returns(true)

    result = @importer.import

    assert_equal 1, result[:transactions_failed]
    assert_equal 0, result[:balances_failed]
  end

  test "duplicate CLBD balances without metadata pick the lower one on a depository account (#3188)" do
    link_account(Depository.create!)
    stub_balances(clbd("1234.56"), clbd("5834.56"))

    assert_difference "DebugLogEntry.count", 1 do
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    @enable_banking_account.reload
    assert_equal BigDecimal("1234.56"), @enable_banking_account.current_balance
    assert_not @enable_banking_account.balance_verified?, "a heuristic pick must not become a trusted anchor"

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync_warning", entry.category
    assert_equal "lowest", entry.metadata["stage"]
    assert_equal 2, entry.metadata["candidates"].size
  end

  test "a single balance per type marks the balance as verified and logs nothing" do
    stub_balances(clbd("1234.56"))

    assert_no_difference "DebugLogEntry.count" do
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    assert @enable_banking_account.reload.balance_verified?
  end

  test "duplicate balances in different currencies prefer the account currency" do
    link_account(Depository.create!)
    stub_balances(clbd("900.00", currency: "USD"), clbd("1234.56"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal BigDecimal("1234.56"), @enable_banking_account.current_balance
    assert @enable_banking_account.balance_verified?
    assert_equal "currency", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "duplicate balances pointing to different bookings prefer the newer booking" do
    link_account(CreditCard.create!)
    @enable_banking_account.update!(raw_transactions_payload: [
      booked_tx("ref-old", 3.days.ago.to_date, "10.00"),
      booked_tx("ref-new", 1.day.ago.to_date, "20.00")
    ])
    stub_balances(
      clbd("100.00", last_committed_transaction: "ref-old"),
      clbd("80.00", last_committed_transaction: "ref-new")
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("80.00"), @enable_banking_account.reload.current_balance
    assert_equal "last_committed_transaction", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "duplicate balances pointing to the same booking fall through to later stages" do
    link_account(Depository.create!)
    @enable_banking_account.update!(raw_transactions_payload: [ booked_tx("ref-1", 1.day.ago.to_date, "10.00") ])
    stub_balances(
      clbd("5834.56", last_committed_transaction: "ref-1"),
      clbd("1234.56", last_committed_transaction: "ref-1")
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1234.56"), @enable_banking_account.reload.current_balance
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "a gap equal to the credit limit identifies the overdraft-inclusive balance" do
    link_account(Depository.create!)
    @enable_banking_account.update!(credit_limit: BigDecimal("4600.00"))
    stub_balances(clbd("5834.56"), clbd("1234.56"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1234.56"), @enable_banking_account.reload.current_balance
    entry = DebugLogEntry.order(:created_at).last
    assert_equal "credit_limit", entry.metadata["stage"]
    assert_equal "4600.0", entry.metadata["credit_limit"]
  end

  test "a verified previous anchor minus booked outflows picks the matching balance" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(
      balance_verified: true,
      raw_transactions_payload: [ booked_tx("ref-1", 1.day.ago.to_date, "50.00", indicator: "DBIT") ]
    )
    # 1000 - 50 = 950. Adding the outflow instead (1050) would pick 1100.
    stub_balances(clbd("1100.00"), clbd("950.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("950.00"), @enable_banking_account.reload.current_balance
    assert @enable_banking_account.balance_verified?
    assert_equal "anchor", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check abstains when bookings on the anchor day change the answer" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(
      balance_verified: true,
      raw_transactions_payload: [ booked_tx("ref-same-day", 2.days.ago.to_date, "700.00", indicator: "DBIT") ]
    )
    # Without the anchor-day booking 1000 matches, with it 300 does.
    stub_balances(clbd("1000.00"), clbd("300.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("300.00"), @enable_banking_account.reload.current_balance
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check falls back to value_date when booking_date is missing" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    tx = booked_tx("ref-1", 1.day.ago.to_date, "50.00", indicator: "DBIT")
    tx["value_date"] = tx.delete("booking_date")
    @enable_banking_account.update!(balance_verified: true, raw_transactions_payload: [ tx ])
    stub_balances(clbd("1000.00"), clbd("950.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("950.00"), @enable_banking_account.reload.current_balance
    assert_equal "anchor", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check ignores pending rows and bookings before the anchor date" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(
      balance_verified: true,
      raw_transactions_payload: [
        booked_tx("ref-before", 3.days.ago.to_date, "300.00", indicator: "DBIT"),
        booked_tx("ref-pending", 1.day.ago.to_date, "300.00", indicator: "DBIT").merge("status" => "PDNG", "_pending" => true),
        booked_tx("ref-in", 1.day.ago.to_date, "100.00", indicator: "CRDT")
      ]
    )
    stub_balances(clbd("1100.00"), clbd("700.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1100.00"), @enable_banking_account.reload.current_balance
    assert_equal "anchor", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "the anchor check is skipped when the previous balance was not verified" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(balance_verified: false, raw_transactions_payload: [])
    stub_balances(clbd("1000.00"), clbd("800.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("800.00"), @enable_banking_account.reload.current_balance
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "an anchor tie is broken by the newer last_change_date_time" do
    account = link_account(Depository.create!)
    create_anchor(account, amount: 1000, date: 2.days.ago.to_date)
    @enable_banking_account.update!(balance_verified: true, raw_transactions_payload: [])
    stub_balances(
      clbd("1100.00", last_change_date_time: "2026-09-30T08:00:00Z"),
      clbd("900.00", last_change_date_time: "2026-09-29T08:00:00Z")
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("1100.00"), @enable_banking_account.reload.current_balance
    assert_not @enable_banking_account.balance_verified?
    assert_equal "anchor_timestamp", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "a fresher balance whose type is duplicated is not marked as verified" do
    @enable_banking_account.update!(balance_verified: true)
    stub_balances(
      { balance_type: "OPBD", balance_amount: { amount: "100.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-01" },
      { balance_type: "ITAV", balance_amount: { amount: "200.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-29" },
      { balance_type: "ITAV", balance_amount: { amount: "900.00", currency: "EUR" }, credit_debit_indicator: "CRDT", reference_date: "2026-09-29" }
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_not @enable_banking_account.reload.balance_verified?
  end

  test "import counts a raising balance refresh as failed and keeps syncing" do
    link_account(Depository.create!)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.stubs(:fetch_and_store_transactions).returns(success: true, transactions_count: 1)
    @importer.stubs(:fetch_and_update_balance).raises(ActiveRecord::StatementInvalid, "lock timeout")

    result = nil
    assert_nothing_raised { result = @importer.import }

    assert_equal 1, result[:balances_failed]
    assert_equal 1, result[:transactions_imported]
  end

  test "duplicate balances on a credit card keep the first reported entry" do
    link_account(CreditCard.create!)
    stub_balances(clbd("500.00"), clbd("100.00"))

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("500.00"), @enable_banking_account.reload.current_balance
    assert_equal "first", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  private

    def link_account(accountable)
      account = Account.create!(
        family: @family,
        name: "EB linked",
        balance: 0,
        cash_balance: 0,
        currency: "EUR",
        accountable: accountable
      )
      AccountProvider.create!(account: account, provider: @enable_banking_account)
      @enable_banking_account.reload
      account
    end

    def create_anchor(account, amount:, date:)
      account.entries.create!(
        date: date,
        name: "Current balance",
        amount: amount,
        currency: "EUR",
        entryable: Valuation.new(kind: "current_anchor")
      )
    end

    def stub_balances(*balances)
      @mock_provider.stubs(:get_account_balances).returns(balances: balances)
    end

    def clbd(amount, currency: "EUR", **metadata)
      {
        name: "Accounting balance",
        balance_type: "CLBD",
        balance_amount: { amount: amount, currency: currency },
        credit_debit_indicator: "CRDT",
        last_change_date_time: nil,
        reference_date: nil,
        last_committed_transaction: nil
      }.merge(metadata)
    end

    def booked_tx(entry_reference, booking_date, amount, indicator: "DBIT")
      {
        "entry_reference" => entry_reference,
        "status" => "BOOK",
        "booking_date" => booking_date.iso8601,
        "credit_debit_indicator" => indicator,
        "transaction_amount" => { "amount" => amount, "currency" => "EUR" }
      }
    end
end
