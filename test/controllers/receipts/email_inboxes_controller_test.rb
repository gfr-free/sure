require "test_helper"

class Receipts::EmailInboxesControllerTest < ActionDispatch::IntegrationTest
  include ReceiptMailHelper

  setup do
    ensure_tailwind_build
    @user = users(:family_member)
    enable_receipt_preview!(@user)
    sign_in @user
  end

  test "the receipts page offers the address only when the operator configured it" do
    get receipts_url
    assert_response :success
    assert_select "[data-testid=receipt-inbox-address]", count: 0
    assert_no_match I18n.t("receipts.email_inbox.enable"), response.body

    with_receipt_inbox do
      get receipts_url
      assert_match I18n.t("receipts.email_inbox.enable"), response.body

      post receipts_email_inbox_url
      assert_redirected_to receipts_url
      address = Receipt::EmailInbox.address_for(@user.reload)
      assert address.present?

      get receipts_url
      assert_select "[data-testid=receipt-inbox-address][value=?]", address
    end
  end

  test "posting again replaces the address, and delete turns it off" do
    with_receipt_inbox do
      post receipts_email_inbox_url
      first = @user.reload.receipt_inbox_token

      post receipts_email_inbox_url
      assert_not_equal first, @user.reload.receipt_inbox_token
      assert_equal I18n.t("receipts.email_inboxes.create.rotated"), flash[:notice]

      delete receipts_email_inbox_url
      assert_nil @user.reload.receipt_inbox_token
    end
  end

  test "saves the extra senders of the signed-in user only" do
    with_receipt_inbox do
      patch receipts_email_inbox_url, params: { email_inbox: { senders: "shop@example.org" } }
      assert_redirected_to receipts_url
      assert_equal %w[shop@example.org], Receipt::EmailInbox.extra_senders(@user.reload)
      assert_empty Receipt::EmailInbox.extra_senders(users(:family_admin).reload)

      patch receipts_email_inbox_url, params: { email_inbox: { senders: "nope" } }
      assert_equal I18n.t("receipts.email_inboxes.update.invalid", count: 10), flash[:alert]
      assert_equal %w[shop@example.org], Receipt::EmailInbox.extra_senders(@user.reload)
    end
  end

  test "is unavailable without configuration, preview features or as a guest" do
    post receipts_email_inbox_url
    assert_redirected_to receipts_url
    assert_nil @user.reload.receipt_inbox_token

    with_receipt_inbox do
      @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
      post receipts_email_inbox_url
      assert_redirected_to root_url

      enable_receipt_preview!(@user)
      @user.update_columns(role: "guest")
      post receipts_email_inbox_url
      assert_nil @user.reload.receipt_inbox_token
    end
  end
end
