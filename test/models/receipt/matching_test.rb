require "test_helper"

class Receipt::MatchingTest < ActiveSupport::TestCase
  include ReceiptPdfHelper

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @account = accounts(:depository)
    @bank_account = accounts(:connected)
  end

  test "auto_match! suggests the one transaction with the amount a day before to five days after the receipt" do
    receipt = receipt_for(amount: 23.5, date: Date.new(2026, 11, 10))
    create_transaction(account: @account, amount: 23.5, date: Date.new(2026, 11, 16))
    create_transaction(account: @account, amount: 23.4, date: Date.new(2026, 11, 12))
    match = create_transaction(account: @account, amount: 23.5, date: Date.new(2026, 11, 9))

    assert_equal match, receipt.auto_match!

    receipt.reload
    assert_equal match, receipt.linked_transaction
    assert receipt.match_pending?
    assert_equal :suggested, receipt.status
    assert_includes @family.receipts.suggested, receipt
    assert_not_includes @family.receipts.open, receipt
    assert_not_includes @family.receipts.done, receipt
    assert_not_includes @family.receipts.linked, receipt, "a suggestion is not a link the user made"
    assert_equal 0, match.attachments.count, "the file is only copied once the user confirms"
  end

  test "auto_match! leaves two fitting transactions to the user" do
    receipt = receipt_for(amount: 10, date: Date.new(2026, 11, 10))
    create_transaction(account: @account, amount: 10, date: Date.new(2026, 11, 10))
    create_transaction(account: @account, amount: 10, date: Date.new(2026, 11, 12))

    assert_nil receipt.auto_match!
    assert_includes @family.receipts.open, receipt.reload
  end

  test "auto_match! skips transfers, excluded entries, other currencies and transactions that have a receipt" do
    receipt = receipt_for(amount: 50, date: Date.new(2026, 11, 10))
    create_transaction(account: @account, amount: 50, date: Date.new(2026, 11, 10)).update!(kind: "funds_movement")
    create_transaction(account: @account, amount: 50, date: Date.new(2026, 11, 10)).entry.update!(excluded: true)
    create_transaction(account: @account, amount: 50, date: Date.new(2026, 11, 10), currency: "EUR")
    taken = create_transaction(account: @account, amount: 50, date: Date.new(2026, 11, 10))
    receipt_for(amount: 50, date: Date.new(2026, 11, 10), user: @admin, name: "other").link_to!(taken, user: @admin)

    assert_nil receipt.auto_match!
  end

  test "auto_match! only looks at accounts the uploader may write to" do
    receipt = receipt_for(amount: 12, date: Date.new(2026, 11, 10), user: @member)
    create_transaction(account: accounts(:credit_card), amount: 12, date: Date.new(2026, 11, 10))

    assert_nil receipt.auto_match!

    shared = create_transaction(account: @account, amount: 12, date: Date.new(2026, 11, 11))
    assert_equal shared, receipt.auto_match!
  end

  test "auto_match! leaves receipts alone that are still being read, dismissed or missing the amount" do
    reading = receipt_for(amount: 7, date: Date.new(2026, 11, 10))
    reading.update!(extraction_status: "pending")
    dismissed = receipt_for(amount: 7, date: Date.new(2026, 11, 10), name: "dismissed")
    dismissed.dismiss!
    no_amount = receipt_for(amount: nil, date: Date.new(2026, 11, 10), name: "no amount")
    create_transaction(account: @account, amount: 7, date: Date.new(2026, 11, 10))

    assert_nil reading.auto_match!
    assert_nil dismissed.auto_match!
    assert_nil no_amount.auto_match!
  end

  test "two receipts for the same purchase do not both take one transaction" do
    first = receipt_for(amount: 30, date: Date.new(2026, 11, 10))
    second = receipt_for(amount: 30, date: Date.new(2026, 11, 10), name: "copy")
    transaction = create_transaction(account: @account, amount: 30, date: Date.new(2026, 11, 10))

    assert_equal transaction, first.auto_match!
    assert_nil second.auto_match!
  end

  test "a receipt that could not be read is matched once the user enters its details" do
    receipt = receipt_for(amount: nil, date: nil)
    receipt.update!(extraction_status: "failed")
    transaction = create_transaction(account: @account, amount: 14, date: Date.new(2026, 11, 10))

    receipt.update_fields!(amount: "14", date: "2026-11-10")

    assert_equal transaction, receipt.auto_match!
  end

  test "changing the amount or date of a suggested receipt drops the suggestion" do
    receipt = receipt_for(amount: 45, date: Date.new(2026, 11, 10))
    create_transaction(account: @account, amount: 45, date: Date.new(2026, 11, 10))
    receipt.auto_match!

    receipt.update_fields!(merchant_name: "Shop")
    assert receipt.reload.suggested?, "a new merchant name keeps the suggestion"

    receipt.update_fields!(amount: "54")
    receipt.reload
    assert_nil receipt.transaction_id
    assert_empty receipt.rejected_matches
  end

  test "confirm_match! copies the file and marks the link confirmed" do
    receipt = receipt_for(amount: 18, date: Date.new(2026, 11, 10))
    transaction = create_transaction(account: @account, amount: 18, date: Date.new(2026, 11, 11))
    receipt.auto_match!

    receipt.confirm_match!(user: @admin)

    receipt.reload
    assert receipt.match_confirmed?
    assert_equal :linked, receipt.status
    assert_includes @family.receipts.done, receipt
    assert_includes @family.receipts.linked, receipt
    assert_equal 1, transaction.attachments.count
    assert_not receipt.created_transaction?
  end

  test "confirm_match! refuses a user who can no longer write to the account" do
    receipt = receipt_for(amount: 18, date: Date.new(2026, 11, 10), user: @member)
    transaction = create_transaction(account: @account, amount: 18, date: Date.new(2026, 11, 11))
    receipt.auto_match!
    account_shares(:depository_shared_with_member).update!(permission: "read_only")

    # The share change already released the suggestion.
    assert_raises(ActiveRecord::RecordInvalid) { receipt.confirm_match!(user: @member) }
    assert_nil receipt.reload.transaction_id
    assert_equal 0, transaction.attachments.count
  end

  test "reject_match! unlinks the receipt and never suggests the pair again" do
    receipt = receipt_for(amount: 18, date: Date.new(2026, 11, 10))
    transaction = create_transaction(account: @account, amount: 18, date: Date.new(2026, 11, 11))
    receipt.auto_match!

    receipt.reject_match!

    receipt.reload
    assert_nil receipt.transaction_id
    assert_equal :open, receipt.status
    assert_equal [ transaction.id ], receipt.rejected_matches.pluck(:transaction_id)
    assert_nil receipt.auto_match!
    assert_raises(ActiveRecord::RecordInvalid) { receipt.reject_match! }
  end

  test "linking by hand replaces a suggestion" do
    receipt = receipt_for(amount: 18, date: Date.new(2026, 11, 10))
    create_transaction(account: @account, amount: 18, date: Date.new(2026, 11, 11))
    receipt.auto_match!
    other = create_transaction(account: @account, amount: 18.5, date: Date.new(2026, 11, 20))

    receipt.link_to!(other, user: @admin)

    assert_equal other, receipt.reload.linked_transaction
    assert receipt.match_confirmed?
  end

  test "dismissing a suggested receipt drops the suggestion without rejecting it" do
    receipt = receipt_for(amount: 18, date: Date.new(2026, 11, 10))
    transaction = create_transaction(account: @account, amount: 18, date: Date.new(2026, 11, 11))
    receipt.auto_match!

    receipt.dismiss!
    assert_nil receipt.reload.transaction_id
    assert_empty receipt.rejected_matches

    receipt.reopen!
    assert_equal transaction, receipt.auto_match!
  end

  test "deleting a suggested transaction returns the receipt to the open receipts" do
    receipt = receipt_for(amount: 18, date: Date.new(2026, 11, 10))
    transaction = create_transaction(account: @account, amount: 18, date: Date.new(2026, 11, 11))
    receipt.auto_match!

    transaction.entry.destroy!

    receipt.reload
    assert_equal :open, receipt.status
    assert_includes @family.receipts.open, receipt
    assert_not_includes @family.receipts.suggested, receipt
  end

  test "merging a pending booking into the posted one keeps the receipt" do
    receipt = receipt_for(amount: 18, date: Date.new(2026, 11, 10))
    pending_tx = create_transaction(account: @account, amount: 18, date: Date.new(2026, 11, 10))
    posted_tx = create_transaction(account: @account, amount: 18, date: Date.new(2026, 11, 12))
    receipt.link_to!(pending_tx, user: @admin)
    pending_tx.update!(extra: { "simplefin" => { "pending" => true }, "potential_posted_match" => { "entry_id" => posted_tx.entry.id, "reason" => "test", "posted_amount" => "18.0" } })

    assert pending_tx.merge_with_duplicate!

    assert_equal posted_tx, receipt.reload.linked_transaction
  end

  test "a rejection follows the pending booking into the posted one" do
    receipt = receipt_for(amount: 20, date: Date.new(2026, 11, 10))
    pending_tx = create_transaction(account: @account, amount: 20, date: Date.new(2026, 11, 10))
    receipt.auto_match!
    receipt.reject_match!
    posted_tx = create_transaction(account: @account, amount: 20, date: Date.new(2026, 11, 12))
    pending_tx.update!(extra: { "simplefin" => { "pending" => true }, "potential_posted_match" => { "entry_id" => posted_tx.entry.id, "reason" => "test", "posted_amount" => "20.0" } })

    assert pending_tx.merge_with_duplicate!

    assert_equal [ posted_tx.id ], receipt.rejected_matches.pluck(:transaction_id)
    assert_nil receipt.auto_match!
  end

  test "a suggestion is dropped when the posted booking was already rejected" do
    receipt = receipt_for(amount: 20, date: Date.new(2026, 11, 10))
    posted_tx = create_transaction(account: @account, amount: 20, date: Date.new(2026, 11, 12))
    receipt.rejected_matches.create!(transaction_id: posted_tx.id)
    pending_tx = create_transaction(account: @account, amount: 20, date: Date.new(2026, 11, 10))
    assert_equal pending_tx, receipt.auto_match!
    pending_tx.update!(extra: { "simplefin" => { "pending" => true }, "potential_posted_match" => { "entry_id" => posted_tx.entry.id, "reason" => "test", "posted_amount" => "20.0" } })

    assert pending_tx.merge_with_duplicate!

    receipt.reload
    assert_nil receipt.transaction_id
    assert_equal :open, receipt.status
  end

  test "auto_match_open suggests transactions after a sync and records failures" do
    receipt = receipt_for(amount: 61, date: Date.new(2026, 11, 10))
    transaction = create_transaction(account: @account, amount: 61, date: Date.new(2026, 11, 11))

    Receipt.auto_match_open(@family)

    assert_equal transaction, receipt.reload.linked_transaction

    other = receipt_for(amount: 62, date: Date.new(2026, 11, 10), name: "boom")
    Receipt.any_instance.stubs(:auto_match!).raises(StandardError, "secret")
    assert_difference -> { DebugLogEntry.count }, 1 do
      Receipt.auto_match_open(@family)
    end
    assert_not_includes DebugLogEntry.last.message, "secret"
    assert_nil other.reload.transaction_id
  end

  test "the family sync runs the receipt matching after the transfer matching" do
    sequence = sequence("post sync")
    @family.expects(:auto_match_transfers!).in_sequence(sequence)
    Receipt.expects(:auto_match_open).with(@family).in_sequence(sequence)
    @family.stubs(:backfill_provider_merchant_logos)

    Family::Syncer.new(@family).perform_post_sync
  end

  test "a manual account's sync runs the receipt matching, a bank account's does not" do
    Receipt.expects(:auto_match_open).with(@family).once
    Account::Syncer.new(@account).perform_post_sync

    Receipt.expects(:auto_match_open).never
    Account::Syncer.new(@bank_account).perform_post_sync
  end

  test "a receipt waits for the bank before it is recorded on a bank-synced account" do
    travel_to Date.new(2026, 11, 12) do
      receipt = receipt_for(amount: 20, date: Date.new(2026, 11, 10))

      assert receipt.awaiting_bank?
      assert_equal Date.new(2026, 11, 17), receipt.bank_wait_until
      error = assert_raises(ActiveRecord::RecordInvalid) do
        receipt.create_transaction!(account: @bank_account, user: @admin, name: "Shop", date: receipt.date, amount: receipt.amount, currency: "USD")
      end
      assert_match I18n.l(Date.new(2026, 11, 17)), error.record.errors.full_messages.to_sentence

      # A cash or other manual account needs no wait.
      assert receipt.create_transaction!(account: @account, user: @admin, name: "Shop", date: receipt.date, amount: receipt.amount, currency: "USD")
    end
  end

  test "the wait ends after the family's number of days" do
    @family.update!(receipt_bank_wait_days: 3)
    receipt = receipt_for(amount: 20, date: Date.new(2026, 11, 10))

    travel_to Date.new(2026, 11, 13) do
      assert_not receipt.awaiting_bank?
      assert receipt.create_transaction!(account: @bank_account, user: @admin, name: "Shop", date: receipt.date, amount: receipt.amount, currency: "USD")
    end
  end

  test "a wait of zero days never holds a receipt back" do
    @family.update!(receipt_bank_wait_days: 0)
    receipt = receipt_for(amount: 20, date: Date.new(2026, 11, 13))

    travel_to Date.new(2026, 11, 12) do
      assert_not receipt.awaiting_bank?
      assert receipt.create_transaction!(account: @bank_account, user: @admin, name: "Shop", date: receipt.date, amount: receipt.amount, currency: "USD")
    end
  end

  test "a suggestion that changed is neither confirmed nor rejected" do
    receipt = receipt_for(amount: 33, date: Date.new(2026, 11, 10))
    shown = create_transaction(account: @account, amount: 33, date: Date.new(2026, 11, 10))
    assert_equal shown, receipt.auto_match!
    other = create_transaction(account: @account, amount: 33, date: Date.new(2026, 11, 11))
    receipt.update!(linked_transaction: other)

    assert_raises(ActiveRecord::RecordInvalid) { receipt.confirm_match!(user: @admin, transaction_id: shown.id) }
    assert_raises(ActiveRecord::RecordInvalid) { receipt.reject_match!(transaction_id: shown.id) }
    assert receipt.reload.match_pending?
    assert_not receipt.rejected_matches.exists?

    receipt.confirm_match!(user: @admin, transaction_id: other.id)
    assert receipt.reload.match_confirmed?
  end

  test "dismissing a receipt that got a suggestion meanwhile drops the suggestion" do
    receipt = receipt_for(amount: 44, date: Date.new(2026, 11, 10))
    create_transaction(account: @account, amount: 44, date: Date.new(2026, 11, 10))
    stale = Receipt.find(receipt.id)
    assert receipt.auto_match!

    stale.dismiss!

    stale.reload
    assert stale.dismissed_at?
    assert_nil stale.transaction_id
  end

  test "a merge drops a suggestion for a pair the moved rejection covers" do
    receipt = receipt_for(amount: 21, date: Date.new(2026, 11, 10))
    pending_tx = create_transaction(account: @account, amount: 21, date: Date.new(2026, 11, 10))
    receipt.rejected_matches.create!(transaction_id: pending_tx.id)
    posted_tx = create_transaction(account: @account, amount: 21, date: Date.new(2026, 11, 12))
    receipt.update!(linked_transaction: posted_tx, match_status: "pending", linked_at: Time.current)
    pending_tx.update!(extra: { "simplefin" => { "pending" => true }, "potential_posted_match" => { "entry_id" => posted_tx.entry.id, "reason" => "test", "posted_amount" => "21.0" } })

    assert pending_tx.merge_with_duplicate!

    receipt.reload
    assert_nil receipt.transaction_id
    assert_equal [ posted_tx.id ], receipt.rejected_matches.pluck(:transaction_id)
  end

  test "a merge keeps one suggestion on the posted booking, and none next to a confirmed receipt" do
    first = receipt_for(amount: 22, date: Date.new(2026, 11, 10), name: "first")
    second = receipt_for(amount: 22, date: Date.new(2026, 11, 10), name: "second")
    pending_tx = create_transaction(account: @account, amount: 22, date: Date.new(2026, 11, 10))
    posted_tx = create_transaction(account: @account, amount: 22, date: Date.new(2026, 11, 12))
    first.update!(linked_transaction: pending_tx, match_status: "pending", linked_at: 2.hours.ago)
    second.update!(linked_transaction: posted_tx, match_status: "pending", linked_at: 1.hour.ago)
    pending_tx.update!(extra: { "simplefin" => { "pending" => true }, "potential_posted_match" => { "entry_id" => posted_tx.entry.id, "reason" => "test", "posted_amount" => "22.0" } })

    assert pending_tx.merge_with_duplicate!

    assert_equal posted_tx, first.reload.linked_transaction
    assert_nil second.reload.transaction_id

    third = receipt_for(amount: 23, date: Date.new(2026, 11, 10), name: "third")
    fourth = receipt_for(amount: 23, date: Date.new(2026, 11, 10), name: "fourth")
    pending_tx = create_transaction(account: @account, amount: 23, date: Date.new(2026, 11, 10))
    posted_tx = create_transaction(account: @account, amount: 23, date: Date.new(2026, 11, 12))
    third.link_to!(posted_tx, user: @admin)
    fourth.update!(linked_transaction: pending_tx, match_status: "pending", linked_at: Time.current)
    pending_tx.update!(extra: { "simplefin" => { "pending" => true }, "potential_posted_match" => { "entry_id" => posted_tx.entry.id, "reason" => "test", "posted_amount" => "23.0" } })

    assert pending_tx.merge_with_duplicate!

    assert_equal posted_tx, third.reload.linked_transaction
    assert_nil fourth.reload.transaction_id
  end

  test "the family only accepts the offered waiting periods" do
    @family.receipt_bank_wait_days = 8
    assert_not @family.valid?

    @family.receipt_bank_wait_days = 0
    assert @family.valid?
  end

  test "a dismissed receipt still waits for the bank before it is recorded on a bank-synced account" do
    travel_to Date.new(2026, 11, 12) do
      receipt = receipt_for(amount: 20, date: Date.new(2026, 11, 10))
      receipt.dismiss!

      assert_no_difference -> { Entry.count } do
        assert_raises(ActiveRecord::RecordInvalid) do
          receipt.create_transaction!(account: @bank_account, user: @admin, name: "Shop", date: receipt.date, amount: receipt.amount, currency: "USD")
        end
      end
    end
  end

  test "auto_match! checks the transaction again once it holds the lock" do
    receipt = receipt_for(amount: 12, date: Date.new(2026, 11, 10))
    transaction = create_transaction(account: @account, amount: 12, date: Date.new(2026, 11, 10))
    # Excluded by another request between the candidate query and the lock.
    Transaction.any_instance.stubs(:with_lock).with { transaction.entry.update_columns(excluded: true) }.yields

    assert_nil receipt.auto_match!
    assert_nil receipt.reload.transaction_id
  end

  test "link_to! checks write access again after copying the file" do
    receipt = receipt_for(amount: 8, date: Date.new(2026, 11, 10))
    transaction = create_transaction(account: @account, amount: 8, date: Date.new(2026, 11, 10))
    receipt.stubs(:writable_account?).returns(true).then.returns(false)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(ActiveRecord::RecordNotFound) { receipt.link_to!(transaction, user: @admin) }
    end
    assert_nil receipt.reload.transaction_id
  end

  test "removing the uploader's share releases their suggestion on that account" do
    receipt = receipt_for(amount: 14, date: Date.new(2026, 11, 10), user: @member)
    create_transaction(account: @account, amount: 14, date: Date.new(2026, 11, 10))
    assert receipt.auto_match!

    account_shares(:depository_shared_with_member).destroy!

    receipt.reload
    assert_nil receipt.transaction_id
    assert_nil receipt.match_status
    assert_includes @family.receipts.open, receipt
  end

  test "a share that loses write access releases the suggestion, other changes keep it" do
    receipt = receipt_for(amount: 15, date: Date.new(2026, 11, 10), user: @member)
    create_transaction(account: @account, amount: 15, date: Date.new(2026, 11, 10))
    assert receipt.auto_match!
    share = account_shares(:depository_shared_with_member)

    share.update!(include_in_finances: false)
    assert receipt.reload.suggested?

    # Only full control may write; read_write annotates.
    share.update!(permission: "read_write")
    assert_nil receipt.reload.transaction_id
  end

  test "confirming a suggestion on an account the user can no longer write to is refused with a message" do
    receipt = receipt_for(amount: 16, date: Date.new(2026, 11, 10), user: @member)
    create_transaction(account: @account, amount: 16, date: Date.new(2026, 11, 10))
    assert receipt.auto_match!
    receipt.stubs(:writable_account?).returns(false)

    error = assert_raises(ActiveRecord::RecordInvalid) { receipt.confirm_match!(user: @member) }
    assert_match I18n.t("activerecord.errors.models.receipt.attributes.base.suggestion_unavailable"), error.record.errors.full_messages.to_sentence
    assert receipt.reload.match_pending?
  end

  private
    def receipt_for(amount:, date:, user: @admin, name: "receipt")
      receipt = Receipt.create_from_upload!(family: @family, user: user,
                                            file: uploaded_receipt(receipt_pdf([ name, "Total #{amount}" ]), filename: "#{name}.pdf"))
      receipt.update!(amount: amount, date: date, currency: "USD", extraction_status: "completed")
      receipt
    end

    def create_transaction(account:, amount:, date:, currency: "USD")
      account.entries.create!(name: "Purchase", date: date, amount: amount, currency: currency, entryable: Transaction.new).transaction
    end
end
