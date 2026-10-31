require "application_system_test_case"

class TransactionAttachmentsOnCreateTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    # The name comes from the category, so the test doesn't depend on typing
    # into the description combobox.
    @user.family.update!(auto_sync_on_login: false, auto_generate_transaction_names: true)
    sign_in @user
  end

  test "files picked in the new-transaction dialog are attached to the created transaction" do
    visit new_transaction_url(account_id: accounts(:depository).id)

    find("input[name='entry[amount]']").set("42.00")
    select_ds("Category", categories(:food_and_drink))
    find("summary", text: /details/i).click
    attach_file "entry_attachments", file_fixture("profile_image.png"), make_visible: true
    assert_text "profile_image.png"

    click_button "Add transaction"
    assert_text "Transaction created"

    entry = @user.family.entries.order(created_at: :desc).first
    assert_equal categories(:food_and_drink), entry.transaction.category
    assert_equal [ "profile_image.png" ], entry.transaction.attachments.map { |a| a.filename.to_s }
  end

  test "an oversized file blocks the submit and says why" do
    big_file = Tempfile.new([ "big", ".pdf" ])
    big_file.write("0" * (Transaction::MAX_ATTACHMENT_SIZE + 1))
    big_file.close

    visit new_transaction_url(account_id: accounts(:depository).id)
    find("input[name='entry[amount]']").set("42.00")
    select_ds("Category", categories(:food_and_drink))
    find("summary", text: /details/i).click
    attach_file "entry_attachments", big_file.path, make_visible: true
    assert_text "File too large (max 10MB)"

    assert_no_difference "Entry.count" do
      click_button "Add transaction"
      assert_no_text "Transaction created"
    end
  ensure
    big_file&.unlink
  end
end
