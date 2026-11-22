require "test_helper"

class Receipt::EmailInboxTest < ActiveSupport::TestCase
  include ReceiptPdfHelper
  include ReceiptMailHelper

  setup do
    @user = users(:family_admin)
    enable_receipt_preview!(@user)
  end

  test "the feature is hidden until the operator sets a base address" do
    with_env_overrides("RECEIPT_INBOX_ADDRESS" => nil) do
      Receipt::EmailInbox.enable!(@user)

      assert_not Receipt::EmailInbox.configured?
      assert_nil Receipt::EmailInbox.address_for(@user)
    end

    with_env_overrides("RECEIPT_INBOX_ADDRESS" => "receipts+x@mail.example.com", "ACTION_MAILBOX_INGRESS" => "relay") do
      assert_not Receipt::EmailInbox.configured?
    end

    # An address without an ingress or IMAP would never receive anything.
    with_env_overrides("RECEIPT_INBOX_ADDRESS" => "receipts@mail.example.com", "ACTION_MAILBOX_INGRESS" => nil, "RECEIPT_INBOX_IMAP_HOST" => nil) do
      assert_not Receipt::EmailInbox.configured?
    end
    with_env_overrides("RECEIPT_INBOX_ADDRESS" => "receipts@mail.example.com", "ACTION_MAILBOX_INGRESS" => nil,
                       "RECEIPT_INBOX_IMAP_HOST" => "imap.example.com", "RECEIPT_INBOX_IMAP_USERNAME" => "u", "RECEIPT_INBOX_IMAP_PASSWORD" => "p") do
      assert Receipt::EmailInbox.configured?
    end
  end

  test "a user with an unrelated invalid attribute can still manage the address" do
    @user.update_columns(default_period: "no_such_period")

    Receipt::EmailInbox.enable!(@user)
    Receipt::EmailInbox.update_senders!(@user, "shop@example.org")

    assert @user.reload.receipt_inbox_token.present?
    assert_equal %w[shop@example.org], Receipt::EmailInbox.extra_senders(@user)
  end

  test "each user gets a private plus address, and a new one replaces the old" do
    with_receipt_inbox do
      assert_nil Receipt::EmailInbox.address_for(@user)

      Receipt::EmailInbox.enable!(@user)
      first = Receipt::EmailInbox.address_for(@user)
      assert_match(/\Areceipts\+[a-z0-9]{24}@mail\.example\.com\z/, first)

      Receipt::EmailInbox.enable!(@user)
      assert_not_equal first, Receipt::EmailInbox.address_for(@user)

      Receipt::EmailInbox.disable!(@user)
      assert_nil Receipt::EmailInbox.address_for(@user)
    end
  end

  test "extra senders are normalized and validated" do
    Receipt::EmailInbox.update_senders!(@user, "Work@Example.com\nshop@example.org, work@example.com #{@user.email.upcase}")

    assert_equal %w[work@example.com shop@example.org], Receipt::EmailInbox.extra_senders(@user.reload)

    assert_raises(ActiveRecord::RecordInvalid) { Receipt::EmailInbox.update_senders!(@user, "not-an-address") }
    too_many = (1..11).map { |n| "sender#{n}@example.com" }.join("\n")
    assert_raises(ActiveRecord::RecordInvalid) { Receipt::EmailInbox.update_senders!(@user, too_many) }
    assert_equal %w[work@example.com shop@example.org], Receipt::EmailInbox.extra_senders(@user.reload)
  end

  test "the login address does not count towards the sender limit and plus addresses are allowed" do
    ten = (1..9).map { |n| "sender#{n}@example.com" } + [ "buyer+receipts@example.org" ]
    Receipt::EmailInbox.update_senders!(@user, (ten + [ @user.email ]).join("\n"))

    assert_equal ten, Receipt::EmailInbox.extra_senders(@user.reload)
  end

  test "turns each attached PDF and photo into a receipt of the addressed user" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      mail = receipt_mail(
        to: Receipt::EmailInbox.address_for(@user), from: @user.email,
        attachments: {
          "invoice.pdf" => receipt_pdf([ "Total 12.40" ]),
          "photo.png" => png_bytes(20.kilobytes),
          "logo.png" => png_bytes(1.kilobyte),
          "notes.txt" => "plain text"
        }
      )

      result = nil
      assert_difference -> { @user.family.receipts.count }, 2 do
        result = Receipt::EmailInbox.receive(mail)
      end

      assert_equal 2, result.created
      assert_equal 2, result.skipped
      receipts = @user.family.receipts.order(:filename)
      assert_equal %w[invoice.pdf photo.png], receipts.map(&:filename)
      assert receipts.all?(&:email?)
      assert receipts.all? { |receipt| receipt.uploaded_by == @user }
    end
  end

  test "the same attachment sent twice is added once" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      pdf = receipt_pdf([ "Total 3.00" ])
      2.times { Receipt::EmailInbox.receive(receipt_mail(to: Receipt::EmailInbox.address_for(@user), from: @user.email, attachments: { "a.pdf" => pdf })) }

      assert_equal 1, @user.family.receipts.where(uploaded_by: @user).count
    end
  end

  test "finds the address in Delivered-To when it is not in To" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      mail = receipt_mail(to: "someone@example.com", from: @user.email, attachments: { "a.pdf" => receipt_pdf([ "Total 1.00" ]) },
                          headers: { "Delivered-To" => Receipt::EmailInbox.address_for(@user).upcase })

      assert Receipt::EmailInbox.addressed_to_inbox?(mail)
      assert_equal 1, Receipt::EmailInbox.receive(mail).created
    end
  end

  test "accepts extra senders and refuses every other sender" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      Receipt::EmailInbox.update_senders!(@user, "shop@example.org")
      address = Receipt::EmailInbox.address_for(@user)
      pdf = receipt_pdf([ "Total 9.00" ])

      assert_nil Receipt::EmailInbox.receive(receipt_mail(to: address, from: "stranger@example.com", attachments: { "a.pdf" => pdf }))
      assert_nil Receipt::EmailInbox.receive(receipt_mail(to: address, from: [ @user.email, "stranger@example.com" ], attachments: { "a.pdf" => pdf }))
      assert_equal 0, @user.family.receipts.count

      assert_equal 1, Receipt::EmailInbox.receive(receipt_mail(to: address, from: "Shop@Example.org", attachments: { "a.pdf" => pdf })).created
    end
  end

  test "refuses unknown, old and switched-off addresses" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      old_address = Receipt::EmailInbox.address_for(@user)
      pdf = receipt_pdf([ "Total 9.00" ])

      assert_nil Receipt::EmailInbox.receive(receipt_mail(to: "receipts+#{'a' * 24}@mail.example.com", from: @user.email, attachments: { "a.pdf" => pdf }))
      assert_nil Receipt::EmailInbox.receive(receipt_mail(to: "receipts@mail.example.com", from: @user.email, attachments: { "a.pdf" => pdf }))
      assert_nil Receipt::EmailInbox.receive(receipt_mail(to: old_address.sub("@mail.", "@other."), from: @user.email, attachments: { "a.pdf" => pdf }))

      Receipt::EmailInbox.enable!(@user)
      assert_nil Receipt::EmailInbox.receive(receipt_mail(to: old_address, from: @user.email, attachments: { "a.pdf" => pdf }))

      address = Receipt::EmailInbox.address_for(@user)
      Receipt::EmailInbox.disable!(@user)
      assert_nil Receipt::EmailInbox.receive(receipt_mail(to: address, from: @user.email, attachments: { "a.pdf" => pdf }))
      assert_equal 0, @user.family.receipts.count
    end
  end

  test "refuses mail for users without preview features, guests and deactivated users" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      mail = -> { receipt_mail(to: Receipt::EmailInbox.address_for(@user), from: @user.email, attachments: { "a.pdf" => receipt_pdf([ "Total 9.00" ]) }) }

      @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
      assert_nil Receipt::EmailInbox.receive(mail.call)

      enable_receipt_preview!(@user)
      @user.update_columns(role: "guest")
      assert_nil Receipt::EmailInbox.receive(mail.call)

      @user.update_columns(role: "admin", active: false)
      assert_nil Receipt::EmailInbox.receive(mail.call)
      assert_equal 0, @user.family.receipts.count
    end
  end

  test "takes at most ten attachments from one mail" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      attachments = (1..12).to_h { |n| [ "r#{n}.pdf", receipt_pdf([ "Receipt #{n}", "Total #{n}.00" ]) ] }

      result = Receipt::EmailInbox.receive(receipt_mail(to: Receipt::EmailInbox.address_for(@user), from: @user.email, attachments: attachments))

      assert_equal 10, result.created
      assert_equal 2, result.skipped
    end
  end

  test "unsupported attachments do not use up the cap" do
    with_receipt_inbox do
      Receipt::EmailInbox.enable!(@user)
      attachments = (1..10).to_h { |n| [ "invite#{n}.ics", "BEGIN:VCALENDAR #{n}" ] }.merge("invoice.pdf" => receipt_pdf([ "Total 4.00" ]))

      result = Receipt::EmailInbox.receive(receipt_mail(to: Receipt::EmailInbox.address_for(@user), from: @user.email, attachments: attachments))

      assert_equal 1, result.created
    end
  end

  private
    # A PNG signature followed by padding: enough for content sniffing and size checks.
    def png_bytes(size)
      ("\x89PNG\r\n\x1A\n".b + "\x00\x00\x00\rIHDR".b).ljust(size, "\x00".b)
    end
end
