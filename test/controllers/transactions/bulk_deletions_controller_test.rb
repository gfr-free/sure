require "test_helper"

class Transactions::BulkDeletionsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
  end

  test "bulk delete" do
    transactions = @user.family.entries.transactions
    delete_count = transactions.size

    assert_difference([ "Transaction.count", "Entry.count" ], -delete_count) do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: {
          entry_ids: transactions.pluck(:id)
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "#{delete_count} transactions deleted", flash[:notice]
  end

  test "bulk delete with rejected transfers" do
    entry = entries(:transaction)
    other_entry = entries(:transfer_out)

    # Create a rejected_transfer referencing the entry's transaction
    RejectedTransfer.create!(
      inflow_transaction: entry.entryable,
      outflow_transaction: other_entry.entryable
    )

    assert_difference "RejectedTransfer.count", -1 do
      assert_difference [ "Transaction.count", "Entry.count" ], -1 do
        post transactions_bulk_deletion_url, params: {
          bulk_delete: {
            entry_ids: [ entry.id ]
          }
        }
      end
    end

    assert_redirected_to transactions_url
    assert_equal "1 transaction deleted", flash[:notice]
  end

  test "deleting one leg of a transfer deletes the whole transfer with its fees" do
    transfer = transfers(:one)
    fee = create_transaction(account: accounts(:depository), amount: 5, name: "Transfer fee").transaction
    fee.update!(transfer: transfer)
    leg_ids = [ entries(:transfer_out).id, entries(:transfer_in).id ]
    Account.any_instance.expects(:sync_later).twice

    assert_difference -> { Transfer.count } => -1, -> { Entry.count } => -3 do
      post transactions_bulk_deletion_url, params: { bulk_delete: { entry_ids: [ transfer.outflow_transaction.entry.id ] } }
    end

    assert_equal "3 transactions deleted", flash[:notice]
    assert_nil flash[:alert]
    assert_not Entry.exists?(id: leg_ids)
    assert_not Transaction.exists?(fee.id)
  end

  test "selecting a transfer and its fee deletes the fee once" do
    transfer = transfers(:one)
    fee_entry = create_transaction(account: accounts(:depository), amount: 5, name: "Transfer fee")
    fee_entry.transaction.update!(transfer: transfer)

    assert_difference -> { Transfer.count } => -1, -> { Entry.count } => -3 do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: { entry_ids: [ transfer.outflow_transaction.entry.id, fee_entry.id ] }
      }
    end

    assert_equal "3 transactions deleted", flash[:notice]
  end

  test "selecting both legs of a transfer deletes it once" do
    assert_difference -> { Transfer.count } => -1, -> { Entry.count } => -2 do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: { entry_ids: [ entries(:transfer_out).id, entries(:transfer_in).id ] }
      }
    end

    assert_equal "2 transactions deleted", flash[:notice]
  end

  test "keeps a transfer whose other side the user cannot write to" do
    sign_in users(:family_member) # depository full_control, credit card read_only
    transfer = transfers(:one)
    entry = create_transaction(account: accounts(:depository), name: "Regular")

    assert_difference -> { Entry.count } => -1 do
      assert_no_difference "Transfer.count" do
        post transactions_bulk_deletion_url, params: {
          bulk_delete: { entry_ids: [ transfer.outflow_transaction.entry.id, entry.id ] }
        }
      end
    end

    assert_equal "1 transaction deleted", flash[:notice]
    assert_equal I18n.t("transactions.bulk_deletions.create.transfers_kept", count: 1), flash[:alert]
    assert Entry.exists?(entries(:transfer_out).id)
    assert Entry.exists?(entries(:transfer_in).id)
  end

  test "keeps a transfer whose fee sits in an account the user cannot write to" do
    sign_in users(:family_member)
    accounts(:credit_card).account_shares.find_by!(user: users(:family_member)).update!(permission: "full_control")
    transfer = transfers(:one)
    create_transaction(account: accounts(:other_asset), amount: 5, name: "Transfer fee").transaction.update!(transfer: transfer)

    assert_no_difference [ "Transfer.count", "Entry.count" ] do
      post transactions_bulk_deletion_url, params: { bulk_delete: { entry_ids: [ transfer.inflow_transaction.entry.id ] } }
    end

    assert_equal I18n.t("transactions.bulk_deletions.create.transfers_kept", count: 1), flash[:alert]
  end
end
