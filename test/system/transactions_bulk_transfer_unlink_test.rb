require "application_system_test_case"

class TransactionsBulkTransferUnlinkTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    login_as @user

    @transfer = transfers(:one)
    @transfer.confirm!
    @transfer_entry = @transfer.outflow_transaction.entry
    @entry = entries(:transaction)
  end

  test "removes the selected transfers and keeps their transactions" do
    visit transactions_path

    select_row(@transfer_entry)

    within "#entry-selection-bar" do
      assert_selector "a[title='#{I18n.t("transactions.selection_bar.edit")}']"
      assert_selector "a[title='#{I18n.t("transactions.selection_bar.duplicate")}']"
      assert_selector "form[action='#{transactions_bulk_deletion_path}'] button"
      find("form[action='#{transactions_bulk_transfer_unlink_path}'] button").click
    end
    within("#confirm-dialog") { click_on I18n.t("transactions.selection_bar.unlink_transfers") }

    assert_text "1 transfer removed"
    assert_not Transfer.exists?(@transfer.id)
    assert Entry.exists?(@transfer_entry.id)
    assert Entry.exists?(@transfer.inflow_transaction.entry.id)
  end

  test "the unlink action only shows when a transfer is selected" do
    visit transactions_path

    select_row(@entry)

    within "#entry-selection-bar" do
      assert_selector "a[title='#{I18n.t("transactions.selection_bar.edit")}']"
      assert_no_selector "form[action='#{transactions_bulk_transfer_unlink_path}']", visible: true
    end
  end

  test "deleting a mixed selection deletes the transfer with both of its transactions" do
    inflow_entry = @transfer.inflow_transaction.entry

    visit transactions_path

    select_row(@transfer_entry)
    select_row(@entry)

    find("form[action='#{transactions_bulk_deletion_path}'] button").click
    within("#confirm-dialog") { click_on I18n.t("shared.custom_confirm.default_btn_text") }

    assert_text "3 transactions deleted"
    assert_not Entry.exists?(@entry.id)
    assert_not Transfer.exists?(@transfer.id)
    assert_not Entry.exists?(@transfer_entry.id)
    assert_not Entry.exists?(inflow_entry.id)
  end

  test "duplicating a transfer opens the new transfer form" do
    visit transactions_path

    select_row(@transfer_entry)
    within("#entry-selection-bar") { find("a[title='#{I18n.t("transactions.selection_bar.duplicate")}']").click }

    within "#modal" do
      assert_selector "form[action='#{transfers_path}']"
      assert_selector "input[name='transfer[amount]'][value='100.0']"
    end
  end

  private
    def select_row(entry)
      find("##{ActionView::RecordIdentifier.dom_id(entry, "selection")}").click
    end
end
