require "test_helper"

class User::CrossFamilyLinksTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_member)
    @old_family = @user.family
    @new_family = Family.create!(name: "Target Family", currency: "USD")
    @moving = Account.create!(family: @old_family, owner: @user, name: "Moving Checking",
                              balance: 100, currency: "USD", accountable: Depository.new)
    @moving_savings = Account.create!(family: @old_family, owner: @user, name: "Moving Savings",
                                      balance: 100, currency: "USD", accountable: Depository.new)
    @staying = accounts(:depository)
  end

  test "transfer_to_family! dissolves a transfer to an account that stays behind and keeps its fees" do
    transfer = create_transfer(from_account: @moving, to_account: @staying, amount: 50)
    transfer.fee_transactions << create_transaction(account: @moving, name: "Transfer fee", amount: 2).entryable
    transfer.fee_transactions << create_transaction(account: @staying, name: "Transfer fee", amount: 1).entryable
    fee_ids = transfer.fee_transactions.pluck(:id)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_not Transfer.exists?(transfer.id)
    outflow = transfer.outflow_transaction.reload
    inflow = transfer.inflow_transaction.reload
    assert_equal "standard", outflow.kind
    assert_equal "standard", inflow.kind
    assert_equal @new_family, outflow.entry.account.family
    assert_equal @old_family, inflow.entry.account.family

    assert_equal 2, Transaction.where(id: fee_ids, transfer_id: nil).count
  end

  test "transfer_to_family! keeps a transfer between two moving accounts" do
    transfer = create_transfer(from_account: @moving, to_account: @moving_savings, amount: 50)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert Transfer.exists?(transfer.id)
    assert_equal "funds_movement", transfer.inflow_transaction.reload.kind
  end

  test "transfer_to_family! moves a recurring series and its occurrences with the account" do
    series = create_series(account: @moving)
    occurrence = series.recurring_occurrences.create!(
      family: @old_family, original_due_on: Date.current + 10.days, due_on: Date.current + 10.days,
      currency: "USD", expected_amount: 10, status: "scheduled"
    )

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_equal @new_family.id, series.reload.family_id
    assert_equal @new_family.id, occurrence.reload.family_id
    assert_equal [ @new_family.id ], RecurringOccurrence.where(recurring_transaction_id: series.id).distinct.pluck(:family_id)
  end

  test "transfer_to_family! moves a recurring transfer between two moving accounts" do
    series = create_series(account: @moving, destination_account: @moving_savings)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_equal @new_family.id, series.reload.family_id
  end

  test "transfer_to_family! removes a recurring transfer to an account that stays behind" do
    outgoing = create_series(account: @moving, destination_account: @staying, name: "Out")
    incoming = create_series(account: @staying, destination_account: @moving, name: "In")
    unrelated = create_series(account: @staying, name: "Stays")

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_not RecurringTransaction.exists?(outgoing.id)
    assert_not RecurringTransaction.exists?(incoming.id)
    assert_equal @old_family.id, unrelated.reload.family_id
  end

  test "transfer_to_family! moves an import whose records all move" do
    import = TransactionImport.create!(family: @old_family, account: @moving, status: "complete")
    entry = create_transaction(account: @moving)
    entry.update!(import: import)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_equal @new_family.id, import.reload.family_id
    assert_equal import.id, entry.reload.import_id
  end

  test "transfer_to_family! clears mappings of a moving import to the old family's records" do
    import = TransactionImport.create!(family: @old_family, account: @moving, status: "complete")
    category_mapping = import.mappings.create!(type: "Import::CategoryMapping", key: "Food", mappable: categories(:food_and_drink))
    moving_account_mapping = import.mappings.create!(type: "Import::AccountMapping", key: "Moving", mappable: @moving)
    staying_account_mapping = import.mappings.create!(type: "Import::AccountMapping", key: "Staying", mappable: @staying)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_nil category_mapping.reload.mappable
    assert_equal @moving, moving_account_mapping.reload.mappable
    assert_nil staying_account_mapping.reload.mappable
  end

  test "transfer_to_family! takes a moving import out of a session that stays behind" do
    session = ImportSession.create!(family: @old_family)
    moving_import = TransactionImport.create!(family: @old_family, account: @moving, import_session: session, status: "complete",
                                                  sequence: 1, checksum: "a" * 64)
    staying_import = TransactionImport.create!(family: @old_family, account: @staying, import_session: session, status: "complete",
                                               sequence: 2, checksum: "b" * 64)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_equal @new_family.id, moving_import.reload.family_id
    assert_nil moving_import.import_session_id
    assert_equal session.id, staying_import.reload.import_session_id
    assert_equal @old_family.id, session.reload.family_id
  end

  test "reverting an import that stays behind leaves the moved records alone" do
    import = AccountImport.create!(family: @old_family, status: "complete")
    @moving.update!(import: import)
    staying_account = Account.create!(family: @old_family, owner: users(:family_admin), name: "Imported Staying",
                                      balance: 10, currency: "USD", accountable: Depository.new, import: import)
    moving_entry = create_transaction(account: @moving_savings)
    moving_entry.update!(import: import)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_equal @old_family.id, import.reload.family_id
    assert_nil @moving.reload.import_id
    assert_nil moving_entry.reload.import_id

    import.revert

    assert Account.exists?(@moving.id)
    assert Entry.exists?(moving_entry.id)
    assert_not Account.exists?(staying_account.id)
  end

  test "an import left behind lets go of a moved account it was tied to" do
    import = TransactionImport.create!(family: @old_family, account: @moving, status: "complete")
    staying_entry = create_transaction(account: @staying)
    staying_entry.update!(import: import)

    @user.transfer_to_family!(@new_family, role: "admin")

    import.reload
    assert_equal @old_family.id, import.family_id
    assert_nil import.account_id
    assert_equal import.id, staying_entry.reload.import_id
  end

  test "transfer_to_family! detaches a fee on the other side of a transfer that stays whole" do
    transfer = create_transfer(from_account: @moving, to_account: @moving_savings, amount: 50)
    fee = create_transaction(account: @staying, name: "Transfer fee", amount: 1).entryable
    transfer.fee_transactions << fee

    @user.transfer_to_family!(@new_family, role: "admin")

    assert Transfer.exists?(transfer.id)
    assert_nil fee.reload.transfer_id
  end

  test "transfer_to_family! detaches a moving fee from a transfer that stays behind" do
    other_staying = accounts(:credit_card)
    transfer = create_transfer(from_account: @staying, to_account: other_staying, amount: 50)
    fee = create_transaction(account: @moving, name: "Transfer fee", amount: 1).entryable
    transfer.fee_transactions << fee

    @user.transfer_to_family!(@new_family, role: "admin")

    assert Transfer.exists?(transfer.id)
    assert_nil fee.reload.transfer_id
  end

  test "transfer_to_family! drops a rejected match between a moving and a remaining account" do
    outflow = create_transaction(account: @moving, amount: 50).entryable
    inflow = create_transaction(account: @staying, amount: -50).entryable
    rejected = RejectedTransfer.create!(inflow_transaction: inflow, outflow_transaction: outflow)

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_not RejectedTransfer.exists?(rejected.id)
  end

  test "transfer_to_family! clears the old family's category and merchant on a moving series" do
    series = RecurringTransaction.create!(
      family: @old_family, account: @moving, merchant: merchants(:netflix), category: categories(:food_and_drink),
      amount: 10, currency: "USD", expected_day_of_month: 5,
      last_occurrence_date: Date.current, next_expected_date: Date.current + 1.month
    )

    @user.transfer_to_family!(@new_family, role: "admin")

    series.reload
    assert_equal @new_family.id, series.family_id
    assert_nil series.category_id
    assert_nil series.merchant_id
    assert_equal merchants(:netflix).name, series.name
    assert series.valid?, series.errors.full_messages.to_sentence
  end

  test "transfer_to_family! unlinks payments of a series staying behind from moving entries" do
    series = RecurringTransaction.create!(
      family: @old_family, name: "Gym", amount: 10, currency: "USD", expected_day_of_month: 5,
      last_occurrence_date: Date.current, next_expected_date: Date.current + 1.month
    )
    occurrence = series.recurring_occurrences.create!(
      family: @old_family, original_due_on: Date.current + 20.days, due_on: Date.current + 20.days,
      currency: "USD", expected_amount: 10, status: "scheduled"
    )
    moving_entry = create_transaction(account: @moving, amount: 10)
    allocation = RecurringAllocation.create!(recurring_occurrence: occurrence, entry: moving_entry, state: :confirmed,
                                             source: :user_confirmed, allocated_amount: 10, currency: "USD")

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_nil allocation.reload.entry_id
    assert_equal @old_family.id, series.reload.family_id
  end

  test "transfer_to_family! moves a statement import of a moving account" do
    statement = AccountStatement.create_from_upload!(
      family: @old_family, account: @moving,
      file: Rack::Test::UploadedFile.new(StringIO.new("date,amount\n2026-01-01,10\n"), "text/csv", original_filename: "statement.csv")
    )
    import = TransactionImport.create!(family: @old_family, account_statement: statement, status: "complete")

    @user.transfer_to_family!(@new_family, role: "admin")

    assert_equal @new_family.id, import.reload.family_id
    assert_equal statement.id, import.account_statement_id
  end

  private
    def create_series(account:, destination_account: nil, name: "Rent")
      RecurringTransaction.create!(
        family: @old_family, account: account, destination_account: destination_account, name: name,
        amount: 10, currency: "USD", expected_day_of_month: 5,
        last_occurrence_date: Date.current, next_expected_date: Date.current + 1.month
      )
    end
end
