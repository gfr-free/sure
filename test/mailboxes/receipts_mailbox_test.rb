require "test_helper"

class ReceiptsMailboxTest < ActionMailbox::TestCase
  include ReceiptPdfHelper
  include ReceiptMailHelper
  include ActionMailer::TestHelper

  setup do
    @user = users(:family_admin)
    enable_receipt_preview!(@user)
  end

  test "routes mail for a receipt address to the receipts mailbox and delivers it" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      mail = receipt_mail(to: Receipt::EmailInbox.address_for(@user), from: @user.email, attachments: { "a.pdf" => receipt_pdf([ "Total 5.00" ]) })

      inbound_email = nil
      assert_difference -> { @user.family.receipts.count }, 1 do
        inbound_email = receive_inbound_email_from_source(mail.to_s)
      end

      assert inbound_email.delivered?
    end
  end

  test "bounces refused mail without creating receipts" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      mail = receipt_mail(to: Receipt::EmailInbox.address_for(@user), from: "stranger@example.com", attachments: { "a.pdf" => receipt_pdf([ "Total 5.00" ]) })

      inbound_email = nil
      assert_no_difference -> { Receipt.count } do
        inbound_email = receive_inbound_email_from_source(mail.to_s)
      end

      assert inbound_email.bounced?
    end
  end

  test "bounces mail to any other address quietly" do
    with_receipt_inbox do
      mail = receipt_mail(to: "someone@example.com", from: @user.email, attachments: { "a.pdf" => receipt_pdf([ "Total 5.00" ]) })

      inbound_email = nil
      assert_no_emails do
        inbound_email = receive_inbound_email_from_source(mail.to_s)
      end

      assert inbound_email.bounced?
      assert_equal 0, Receipt.count
    end
  end
end
