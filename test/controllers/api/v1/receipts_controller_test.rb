# frozen_string_literal: true

require "test_helper"

class Api::V1::ReceiptsControllerTest < ActionDispatch::IntegrationTest
  include ReceiptPdfHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = @admin.family
    @account = accounts(:depository)
    enable_preview!(@admin)
    enable_preview!(@member)

    @admin.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @api_key = create_api_key(@admin, "read_write")
    @read_only_api_key = create_api_key(@admin, "read")
    @member_api_key = create_api_key(@member, "read_write")
  end

  teardown do
    redis = Redis.new
    [ @api_key, @read_only_api_key, @member_api_key ].compact.each do |key|
      redis.del("api_rate_limit:#{key.id}")
    end
    redis.close
  end

  test "requires authentication" do
    get api_v1_receipts_url
    assert_response :unauthorized

    post api_v1_receipts_url, params: { file: receipt_upload }
    assert_response :unauthorized
  end

  test "requires preview features" do
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))

    get api_v1_receipts_url, headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal "feature_disabled", response.parsed_body["error"]
  end

  test "guests cannot use receipts" do
    @member.update!(role: "guest")

    get api_v1_receipts_url, headers: api_headers(@member_api_key)

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body["error"]
  end

  test "uploads a receipt from the API" do
    assert_difference -> { @family.receipts.count }, 1 do
      post api_v1_receipts_url, params: { file: receipt_upload(filename: "lunch.pdf") }, headers: api_headers(@api_key)
    end

    assert_response :created
    body = response.parsed_body
    receipt = Receipt.find(body["data"]["id"])
    assert_equal @admin, receipt.uploaded_by
    assert_equal "api", receipt.source
    assert_equal "api", body["data"]["source"]
    assert_equal "reading", body["data"]["status"]
    assert_equal "lunch.pdf", body["data"]["filename"]
    assert_equal false, body["meta"]["duplicate"]
  end

  test "returns the existing receipt for a duplicate upload" do
    existing = upload_for(@admin, "lunch.pdf")

    assert_no_difference -> { @family.receipts.count } do
      post api_v1_receipts_url, params: { file: receipt_upload(filename: "lunch.pdf") }, headers: api_headers(@api_key)
    end

    assert_response :ok
    assert_equal existing.id, response.parsed_body["data"]["id"]
    assert_equal true, response.parsed_body["meta"]["duplicate"]
  end

  test "rejects a missing or unsupported file" do
    post api_v1_receipts_url, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    post api_v1_receipts_url,
         params: { file: uploaded_receipt("date,amount\n", filename: "notes.csv", content_type: "text/csv") },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "read-only keys cannot change receipts" do
    receipt = upload_for(@admin, "read.pdf")

    post api_v1_receipts_url, params: { file: receipt_upload }, headers: api_headers(@read_only_api_key)
    assert_response :forbidden

    patch api_v1_receipt_url(receipt), params: { merchant_name: "Shop" }, headers: api_headers(@read_only_api_key)
    assert_response :forbidden

    delete api_v1_receipt_url(receipt), headers: api_headers(@read_only_api_key)
    assert_response :forbidden
    assert Receipt.exists?(receipt.id)
  end

  test "lists only the caller's own receipts" do
    open_receipt = upload_for(@admin, "open.pdf")
    open_receipt.update!(extraction_status: "completed")
    dismissed = upload_for(@admin, "dismissed.pdf")
    dismissed.dismiss!
    other = upload_for(@member, "other.pdf")

    get api_v1_receipts_url, headers: api_headers(@read_only_api_key)

    assert_response :ok
    ids = response.parsed_body["data"].map { |row| row["id"] }
    assert_includes ids, open_receipt.id
    assert_includes ids, dismissed.id
    assert_not_includes ids, other.id
    assert_equal 2, response.parsed_body["meta"]["total_count"]

    get api_v1_receipts_url, params: { content_sha256: open_receipt.content_sha256.upcase }, headers: api_headers(@read_only_api_key)
    assert_equal [ open_receipt.id ], response.parsed_body["data"].map { |row| row["id"] }
  end

  test "status filters follow the status each receipt reports" do
    reading = upload_for(@admin, "reading.pdf")
    open_receipt = upload_for(@admin, "open.pdf")
    open_receipt.update!(extraction_status: "completed")
    linked = upload_for(@admin, "linked.pdf")
    entry = @account.entries.create!(name: "Shop", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)
    linked.link_to!(entry.transaction, user: @admin)
    linked_then_dismissed = upload_for(@admin, "linked-dismissed.pdf")
    linked_then_dismissed.link_to!(entry.transaction, user: @admin)
    linked_then_dismissed.dismiss!
    suggested = suggest(upload_for(@admin, "suggested.pdf"), entry)

    expected = {
      "reading" => [ reading ], "open" => [ open_receipt ], "suggested" => [ suggested ],
      "linked" => [ linked ], "dismissed" => [ linked_then_dismissed ]
    }
    expected.each do |status, receipts|
      get api_v1_receipts_url, params: { status: status }, headers: api_headers(@api_key)

      assert_response :ok
      rows = response.parsed_body["data"]
      assert_equal receipts.map(&:id).sort, rows.map { |row| row["id"] }.sort, status
      assert rows.all? { |row| row["status"] == status }, status
    end
  end

  test "a receipt without a stored file is not found" do
    receipt = upload_for(@admin, "gone.pdf")
    receipt.file.detach

    get file_api_v1_receipt_url(receipt), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "rejects unknown filters" do
    get api_v1_receipts_url, params: { status: "lost" }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    get api_v1_receipts_url, params: { extraction_status: "lost" }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "another user's receipt is not found" do
    other = upload_for(@member, "other.pdf")

    get api_v1_receipt_url(other), headers: api_headers(@api_key)
    assert_response :not_found

    get file_api_v1_receipt_url(other), headers: api_headers(@api_key)
    assert_response :not_found

    delete api_v1_receipt_url(other), headers: api_headers(@api_key)
    assert_response :not_found
    assert Receipt.exists?(other.id)

    get api_v1_receipt_url("not-a-uuid"), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "shows a receipt with its read fields and sources" do
    receipt = upload_for(@admin, "show.pdf")
    receipt.update!(merchant_name: "Corner Shop", amount: 7.25, currency: "USD", date: Date.new(2026, 11, 1),
                    extraction_status: "completed",
                    field_sources: { "amount" => { "source" => "pdf_text", "confidence" => 0.8 } })

    get api_v1_receipt_url(receipt), headers: api_headers(@read_only_api_key)

    assert_response :ok
    data = response.parsed_body["data"]
    assert_equal "open", data["status"]
    assert_equal "Corner Shop", data["merchant_name"]
    assert_equal "7.25", data["amount"]
    assert_equal "2026-11-01", data["date"]
    assert_equal({ "source" => "pdf_text", "confidence" => 0.8 }, data["field_sources"]["amount"])
    assert_nil data["field_sources"]["date"]
    assert_nil data["transaction"]
    assert_not data.key?("raw_text")
  end

  test "downloads the receipt file" do
    receipt = upload_for(@admin, "file.pdf")

    get file_api_v1_receipt_url(receipt), headers: api_headers(@read_only_api_key)

    assert_response :ok
    assert_equal "application/pdf", response.media_type
    assert_equal receipt.file.download, response.body
  end

  test "corrects fields and marks them as manual" do
    receipt = upload_for(@admin, "fix.pdf")

    patch api_v1_receipt_url(receipt),
          params: { merchant_name: "Corner Shop", amount: "7.25", currency: "usd", date: "2026-11-01" },
          headers: api_headers(@api_key)

    assert_response :ok
    receipt.reload
    assert_equal "Corner Shop", receipt.merchant_name
    assert_equal BigDecimal("7.25"), receipt.amount
    assert_equal "USD", receipt.currency
    assert_equal Date.new(2026, 11, 1), receipt.date
    assert_equal "manual", receipt.field_source(:amount)
    assert_equal "manual", response.parsed_body["data"]["field_sources"]["date"]["source"]
  end

  test "a submitted field stays manual even when its value does not change" do
    receipt = upload_for(@admin, "unchanged.pdf")
    assert_nil receipt.date

    patch api_v1_receipt_url(receipt),
          params: { date: nil }.to_json,
          headers: api_headers(@api_key).merge("Content-Type" => "application/json")

    assert_response :ok
    assert_equal "manual", receipt.reload.field_source(:date)
    assert_nil receipt.date
  end

  test "corrected fields that make one transaction fit return a suggestion" do
    receipt = upload_for(@admin, "unread.pdf")
    receipt.update!(extraction_status: "failed")
    entry = @account.entries.create!(name: "Fitting shop", date: Date.new(2026, 11, 6), amount: 12.34, currency: "USD", entryable: Transaction.new)

    patch api_v1_receipt_url(receipt),
          params: { amount: "12.34", currency: "USD", date: "2026-11-05" },
          headers: api_headers(@api_key)

    assert_response :ok
    data = response.parsed_body["data"]
    assert_equal "suggested", data["status"]
    assert_equal entry.transaction.id, data["transaction"]["id"]
  end

  test "rejects fields it cannot read" do
    receipt = upload_for(@admin, "bad.pdf")

    patch api_v1_receipt_url(receipt), params: { date: "01.11.2026" }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    patch api_v1_receipt_url(receipt), params: { amount: "abc" }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    patch api_v1_receipt_url(receipt), params: { currency: "QQQ" }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    patch api_v1_receipt_url(receipt), params: {}, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    assert_nil receipt.reload.amount
  end

  test "lists matching transactions as candidates" do
    receipt = upload_for(@admin, "lunch.pdf")
    receipt.update!(amount: 18.5, currency: "USD", date: Date.current)
    entry = @account.entries.create!(name: "Lunch spot", date: Date.current, amount: 18.5, currency: "USD", entryable: Transaction.new)

    get candidates_api_v1_receipt_url(receipt), headers: api_headers(@read_only_api_key)

    assert_response :ok
    row = response.parsed_body["data"].find { |candidate| candidate["id"] == entry.transaction.id }
    assert_equal "Lunch spot", row["name"]
    assert_equal entry.id, row["entry_id"]
    assert_equal @account.id, row["account"]["id"]
  end

  test "links a receipt to a transaction" do
    receipt = upload_for(@admin, "link.pdf")
    entry = @account.entries.create!(name: "Shop", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)

    post link_api_v1_receipt_url(receipt), params: { transaction_id: entry.transaction.id }, headers: api_headers(@api_key)

    assert_response :ok
    assert_equal entry.transaction, receipt.reload.linked_transaction
    assert_equal 1, entry.transaction.attachments.count
    data = response.parsed_body["data"]
    assert_equal "linked", data["status"]
    assert_equal entry.transaction.id, data["transaction"]["id"]

    post link_api_v1_receipt_url(receipt), params: { transaction_id: entry.transaction.id }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity
    assert_equal 1, entry.transaction.attachments.count
  end

  test "cannot link to a transaction on a read-only account" do
    receipt = upload_for(@member, "member.pdf")
    entry = accounts(:credit_card).entries.create!(name: "Card", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)

    post link_api_v1_receipt_url(receipt), params: { transaction_id: entry.transaction.id }, headers: api_headers(@member_api_key)

    assert_response :not_found
    assert_nil receipt.reload.transaction_id
  end

  test "records a receipt as a new transaction" do
    receipt = upload_for(@admin, "new.pdf")
    receipt.update!(merchant_name: "Bakery", amount: 3.8, currency: "USD", date: Date.current)

    assert_difference -> { @account.entries.count }, 1 do
      post create_transaction_api_v1_receipt_url(receipt), params: { account_id: @account.id }, headers: api_headers(@api_key)
    end

    assert_response :created
    receipt.reload
    assert receipt.created_transaction?
    entry = receipt.linked_transaction.entry
    assert_equal "Bakery", entry.name
    assert_equal BigDecimal("3.8"), entry.amount
    assert_equal Date.current, entry.date
    assert_equal true, response.parsed_body["data"]["created_transaction"]
  end

  test "new transaction values override the read ones" do
    receipt = upload_for(@admin, "override.pdf")

    post create_transaction_api_v1_receipt_url(receipt),
         params: { account_id: @account.id, name: "Kiosk", date: "2026-11-02", amount: "4.10", currency: "USD" },
         headers: api_headers(@api_key)

    assert_response :created
    entry = receipt.reload.linked_transaction.entry
    assert_equal "Kiosk", entry.name
    assert_equal Date.new(2026, 11, 2), entry.date
    assert_equal BigDecimal("4.10"), entry.amount
  end

  test "rejects a new transaction without a date or valid amount" do
    receipt = upload_for(@admin, "bad.pdf")

    assert_no_difference -> { @account.entries.count } do
      post create_transaction_api_v1_receipt_url(receipt),
           params: { account_id: @account.id, amount: "3.80" }, headers: api_headers(@api_key)
      assert_response :unprocessable_entity

      post create_transaction_api_v1_receipt_url(receipt),
           params: { account_id: @account.id, date: "2026-11-02", amount: "abc" }, headers: api_headers(@api_key)
      assert_response :unprocessable_entity

      post create_transaction_api_v1_receipt_url(receipt),
           params: { account_id: @account.id, date: "2026-11-02", amount: "-1" }, headers: api_headers(@api_key)
      assert_response :unprocessable_entity

      post create_transaction_api_v1_receipt_url(receipt),
           params: { account_id: @account.id, date: "2026-11-02", amount: "1e20" }, headers: api_headers(@api_key)
      assert_response :unprocessable_entity
    end
  end

  test "cannot record a new transaction on an account without write access" do
    receipt = upload_for(@member, "member.pdf")

    assert_no_difference -> { accounts(:credit_card).entries.count } do
      post create_transaction_api_v1_receipt_url(receipt),
           params: { account_id: accounts(:credit_card).id, date: "2026-11-02", amount: "1" },
           headers: api_headers(@member_api_key)
    end

    assert_response :not_found
  end

  test "confirms a suggested transaction" do
    entry = @account.entries.create!(name: "Shop", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)
    receipt = suggest(upload_for(@admin, "suggested.pdf"), entry)

    get api_v1_receipt_url(receipt), headers: api_headers(@read_only_api_key)
    data = response.parsed_body["data"]
    assert_equal "suggested", data["status"]
    assert_equal "pending", data["match_status"]
    assert_equal entry.transaction.id, data["transaction"]["id"]

    post confirm_api_v1_receipt_url(receipt), headers: api_headers(@read_only_api_key)
    assert_response :forbidden

    post confirm_api_v1_receipt_url(receipt), headers: api_headers(@api_key)

    assert_response :ok
    assert_equal "linked", response.parsed_body["data"]["status"]
    assert_equal "confirmed", response.parsed_body["data"]["match_status"]
    assert receipt.reload.match_confirmed?
    assert_equal 1, entry.transaction.attachments.count
  end

  test "rejects a suggested transaction" do
    entry = @account.entries.create!(name: "Shop", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)
    receipt = suggest(upload_for(@admin, "suggested.pdf"), entry)

    post reject_api_v1_receipt_url(receipt), headers: api_headers(@api_key)

    assert_response :ok
    assert_nil response.parsed_body["data"]["transaction"]
    assert_nil receipt.reload.transaction_id
    assert receipt.rejected_matches.exists?(transaction_id: entry.transaction.id)
    assert_equal 0, entry.transaction.attachments.count
  end

  test "confirm and reject refuse a suggestion that changed" do
    entry = @account.entries.create!(name: "Shop", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)
    receipt = suggest(upload_for(@admin, "suggested.pdf"), entry)
    stale_id = SecureRandom.uuid

    post confirm_api_v1_receipt_url(receipt), params: { transaction_id: stale_id }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    post reject_api_v1_receipt_url(receipt), params: { transaction_id: stale_id }, headers: api_headers(@api_key)
    assert_response :unprocessable_entity
    assert receipt.reload.match_pending?

    post confirm_api_v1_receipt_url(receipt), params: { transaction_id: entry.transaction.id }, headers: api_headers(@api_key)
    assert_response :ok
    assert receipt.reload.match_confirmed?
  end

  test "confirm and reject need a pending suggestion" do
    receipt = upload_for(@admin, "plain.pdf")

    post confirm_api_v1_receipt_url(receipt), headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    post reject_api_v1_receipt_url(receipt), headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "cannot confirm a suggestion on an account the caller can no longer write to" do
    entry = accounts(:credit_card).entries.create!(name: "Card", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new)
    receipt = suggest(upload_for(@member, "member.pdf"), entry)

    post confirm_api_v1_receipt_url(receipt), headers: api_headers(@member_api_key)

    assert_response :unprocessable_entity
    assert receipt.reload.match_pending?
    assert_equal 0, entry.transaction.attachments.count
  end

  test "dismisses, reopens and deletes a receipt" do
    receipt = upload_for(@admin, "gone.pdf")

    post dismiss_api_v1_receipt_url(receipt), headers: api_headers(@api_key)
    assert_response :ok
    assert_equal "dismissed", response.parsed_body["data"]["status"]

    post reopen_api_v1_receipt_url(receipt), headers: api_headers(@api_key)
    assert_response :ok
    assert_not receipt.reload.dismissed_at?

    assert_difference -> { @family.receipts.count }, -1 do
      delete api_v1_receipt_url(receipt), headers: api_headers(@api_key)
    end
    assert_response :no_content
  end

  test "reopening a receipt that fits one transaction returns a suggestion" do
    receipt = upload_for(@admin, "later.pdf")
    receipt.update!(amount: 9.87, currency: "USD", date: Date.new(2026, 11, 5), extraction_status: "completed", dismissed_at: Time.current)
    entry = @account.entries.create!(name: "Later shop", date: Date.new(2026, 11, 6), amount: 9.87, currency: "USD", entryable: Transaction.new)

    post reopen_api_v1_receipt_url(receipt), headers: api_headers(@api_key)

    assert_response :ok
    data = response.parsed_body["data"]
    assert_equal "suggested", data["status"]
    assert_equal entry.transaction.id, data["transaction"]["id"]
  end

  private
    def enable_preview!(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def receipt_upload(filename: "lunch.pdf")
      uploaded_receipt(receipt_pdf([ "Total 1.00", filename ]), filename: filename)
    end

    def upload_for(user, filename)
      Receipt.create_from_upload!(family: user.family, user: user, file: receipt_upload(filename: filename))
    end

    def suggest(receipt, entry)
      receipt.update!(extraction_status: "completed", linked_transaction: entry.transaction, match_status: "pending", linked_at: Time.current)
      receipt
    end

    def create_api_key(user, scope)
      ApiKey.create!(
        user: user,
        name: "Test #{scope} key",
        scopes: [ scope ],
        display_key: "test_#{scope}_#{SecureRandom.hex(8)}",
        source: scope == "read" ? "mobile" : "web"
      )
    end
end
