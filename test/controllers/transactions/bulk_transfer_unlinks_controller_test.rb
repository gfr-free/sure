require "test_helper"

class Transactions::BulkTransferUnlinksControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
  end

  test "unlinks the selected transfers and keeps both transactions" do
    transfer = create_confirmed_transfer(from: accounts(:depository), to: accounts(:credit_card))
    other = create_confirmed_transfer(from: accounts(:depository), to: accounts(:investment))
    Account.any_instance.expects(:sync_later).times(3)

    assert_difference -> { Transfer.count } => -2, -> { RejectedTransfer.count } => 2 do
      assert_no_difference [ "Entry.count", "Transaction.count" ] do
        post transactions_bulk_transfer_unlink_url, params: {
          bulk_transfer_unlink: {
            entry_ids: [ transfer.outflow_transaction.entry.id, other.inflow_transaction.entry.id ]
          }
        }
      end
    end

    assert_redirected_to transactions_url
    assert_equal "2 transfers removed", flash[:notice]
    assert_nil flash[:alert]
    assert_equal "standard", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  test "selecting both legs of a transfer counts it once" do
    transfer = create_confirmed_transfer(from: accounts(:depository), to: accounts(:credit_card))

    assert_difference -> { Transfer.count } => -1, -> { RejectedTransfer.count } => 1 do
      post transactions_bulk_transfer_unlink_url, params: {
        bulk_transfer_unlink: {
          entry_ids: [ transfer.outflow_transaction.entry.id, transfer.inflow_transaction.entry.id ]
        }
      }
    end

    assert_equal "1 transfer removed", flash[:notice]
  end

  test "leaves selected transactions that are not transfers alone" do
    entry = entries(:transaction)

    assert_no_difference [ "Transfer.count", "Entry.count", "RejectedTransfer.count" ] do
      post transactions_bulk_transfer_unlink_url, params: { bulk_transfer_unlink: { entry_ids: [ entry.id ] } }
    end

    assert_equal "0 transfers removed", flash[:notice]
  end

  test "the next account sync does not match the unlinked pair again" do
    transfer = create_confirmed_transfer(from: accounts(:depository), to: accounts(:credit_card))
    outflow_id = transfer.outflow_transaction_id

    post transactions_bulk_transfer_unlink_url, params: {
      bulk_transfer_unlink: { entry_ids: [ transfer.outflow_transaction.entry.id ] }
    }

    @user.family.auto_match_transfers!

    assert_not Transfer.exists?(outflow_transaction_id: outflow_id)
  end

  test "unlinks a transfer when only one side is accessible" do
    transfer = cross_owner_transfer(outflow_account: accounts(:depository), inflow_account: member_loan)

    assert_difference -> { Transfer.count }, -1 do
      post transactions_bulk_transfer_unlink_url, params: {
        bulk_transfer_unlink: { entry_ids: [ transfer.outflow_transaction.entry.id ] }
      }
    end
  end

  test "keeps a transfer whose fee sits in an account the user cannot write to" do
    transfer = cross_owner_transfer(outflow_account: accounts(:depository), inflow_account: member_loan)
    fee = attach_fee(transfer, account: member_loan)
    Account.any_instance.expects(:sync_later).never

    assert_no_difference [ "Transfer.count", "RejectedTransfer.count" ] do
      post transactions_bulk_transfer_unlink_url, params: {
        bulk_transfer_unlink: { entry_ids: [ transfer.outflow_transaction.entry.id ] }
      }
    end

    assert_equal "0 transfers removed", flash[:notice]
    assert_equal "1 transfer was kept because you lack write access to its accounts or fees", flash[:alert]
    assert Transaction.exists?(fee.id)
  end

  test "keeps a transfer the user can only read" do
    sign_in users(:family_member)
    account_shares(:depository_shared_with_member).update!(permission: "read_only")
    transfer = transfers(:one)

    assert_no_difference [ "Transfer.count", "RejectedTransfer.count" ] do
      post transactions_bulk_transfer_unlink_url, params: {
        bulk_transfer_unlink: { entry_ids: [ transfer.outflow_transaction.entry.id ] }
      }
    end

    assert Transfer.exists?(transfer.id)
  end

  test "ignores transfers of accounts the user cannot see" do
    sign_in users(:family_member)
    transfer = cross_owner_transfer(outflow_account: accounts(:other_asset), inflow_account: accounts(:loan))

    assert_no_difference [ "Transfer.count", "RejectedTransfer.count" ] do
      post transactions_bulk_transfer_unlink_url, params: {
        bulk_transfer_unlink: { entry_ids: [ transfer.outflow_transaction.entry.id ] }
      }
    end

    assert Transfer.exists?(transfer.id)
  end

  test "ignores transfers of another family" do
    sign_in users(:empty)
    transfer = transfers(:one)

    assert_no_difference [ "Transfer.count", "RejectedTransfer.count" ] do
      post transactions_bulk_transfer_unlink_url, params: {
        bulk_transfer_unlink: { entry_ids: [ transfer.outflow_transaction.entry.id ] }
      }
    end

    assert Transfer.exists?(transfer.id)
  end

  test "transfer rows can be selected and the selection bar offers the unlink action" do
    transfer = transfers(:one)

    get transactions_url

    assert_response :success
    checkbox = css_select("input##{ActionView::RecordIdentifier.dom_id(transfer.outflow_transaction.entry, "selection")}").first
    assert_not_nil checkbox
    assert_nil checkbox["disabled"]
    assert_equal "true", checkbox["data-transfer"]
    assert_select "form[action='#{transactions_bulk_transfer_unlink_path}'][data-bulk-select-target='transferAction']"
  end

  private
    def create_confirmed_transfer(from:, to:)
      outflow_entry = create_transaction(date: Date.current, account: from, amount: 500)
      inflow_entry = create_transaction(date: Date.current, account: to, amount: -500)

      Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction).tap(&:confirm!)
    end

    # A loan owned by family_member and not shared with family_admin
    def member_loan
      accounts(:loan).tap { |loan| loan.update!(owner: users(:family_member)) }
    end

    def cross_owner_transfer(outflow_account:, inflow_account:, status: "pending")
      outflow = create_transaction(account: outflow_account, amount: 250, kind: "funds_movement")
      inflow = create_transaction(account: inflow_account, amount: -250, kind: "funds_movement")

      Transfer.create!(outflow_transaction: outflow.transaction, inflow_transaction: inflow.transaction, status: status)
    end

    def attach_fee(transfer, account:)
      create_transaction(account: account, amount: 5, name: "Transfer fee").transaction.tap do |fee|
        fee.update!(transfer: transfer)
      end
    end
end
