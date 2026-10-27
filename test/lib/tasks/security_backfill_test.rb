# frozen_string_literal: true

require "test_helper"

class SecurityBackfillTest < ActiveSupport::TestCase
  # Follows the suite convention (see test/encryption_verification_test.rb):
  # runs only when explicit encryption keys are configured, e.g.
  #
  #   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=test \
  #   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=test \
  #   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=test \
  #   bin/rails test test/lib/tasks/security_backfill_test.rb
  setup do
    skip "Encryption not configured" unless LunchflowAccount.encryption_ready?
    Rails.application.load_tasks unless Rake::Task.task_defined?("security:backfill_encryption")
    Rake::Task["security:backfill_encryption"].reenable
  end

  # Lunchflow is a representative provider model, chosen arbitrarily: the bug
  # this guards against applies identically to every json/jsonb encrypts
  # column the task touches (the Plaid/SimpleFin/Enable Banking/... raw
  # payload columns), via the shared safe_read_field helper.
  test "backfill preserves jsonb payload structure and string fields" do
    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Test", api_key: "seed")
    item.save!(validate: false)
    account = item.lunchflow_accounts.create!(
      name: "Backfill Test Account", currency: "GBP", account_id: "backfill-test-1")

    payload = [ { "id" => "tx-1", "amount" => -4.5, "currency" => "GBP", "date" => "2026-07-01" } ]

    # Simulate rows written before encryption was enabled: bypass the encrypted
    # setters and write plaintext values directly to the columns.
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_accounts SET raw_transactions_payload = ?::jsonb WHERE id = ?",
      payload.to_json, account.id ]))
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_items SET api_key = ? WHERE id = ?", "plaintext-key", item.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    account.reload
    assert_kind_of Array, account.raw_transactions_payload,
      "jsonb payload must decrypt to its original structure, not the JSON text"
    assert_equal "tx-1", account.raw_transactions_payload.first["id"]
    assert_equal "plaintext-key", item.reload.api_key

    # The stored value is ciphertext, not plaintext jsonb
    at_rest = account.read_attribute_before_type_cast(:raw_transactions_payload).to_s
    refute_includes at_rest, "tx-1"
  end

  # Guards the task's field list: dropping :account_number from the
  # SnaptradeAccount entry would leave the model-level encryption test green
  # while pre-encryption rows stayed plaintext.
  test "backfill encrypts a plaintext SnapTrade account number" do
    account = snaptrade_accounts(:fidelity_401k)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE snaptrade_accounts SET account_number = ? WHERE id = ?", "5544332211", account.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    assert_equal "5544332211", account.reload.account_number
    at_rest = ActiveRecord::Base.connection.select_value(
      SnaptradeAccount.where(id: account.id).select(:account_number).to_sql)
    refute_includes at_rest.to_s, "5544332211",
      "account_number must be stored as ciphertext after the backfill"
  end

  # Several payload columns default to {} — Rails presence checks treat empty
  # Hash/Array as absent, so the backfill must gate on nil-ness or empty
  # payloads stay plaintext and raise on every read once keys are live.
  test "backfill encrypts empty json payloads" do
    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Empty Test", api_key: "seed")
    item.save!(validate: false)
    account = item.lunchflow_accounts.create!(
      name: "Backfill Empty Test Account", currency: "GBP", account_id: "backfill-test-2")

    # Plaintext empty payload, as left by a pre-encryption install
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_accounts SET raw_payload = ?::jsonb WHERE id = ?", "{}", account.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    account.reload
    assert_equal({}, account.raw_payload,
      "an empty payload must decrypt cleanly after the backfill, not remain plaintext")
    assert_match(/"p":/, account.read_attribute_before_type_cast(:raw_payload).to_s,
      "the stored value must be an encryption envelope, not plaintext {}")
  end

  # Rows written by a release without IP encryption (for example during a
  # rolling deploy) must end up encrypted, and sessions must keep their digest.
  test "backfill encrypts plaintext IP addresses" do
    session = Session.create!(user: users(:family_admin))
    audit_log = SsoAuditLog.create!(event_type: "login", user: users(:family_admin))
    impersonation_log = impersonation_sessions(:in_progress).logs.create!(path: "/accounts")
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE sessions SET ip_address = ?, ip_address_digest = NULL WHERE id = ?", "192.0.2.20", session.id ]))
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE sso_audit_logs SET ip_address = ? WHERE id = ?", "192.0.2.21", audit_log.id ]))
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE impersonation_session_logs SET ip_address = ? WHERE id = ?", "192.0.2.22", impersonation_log.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    assert_equal "192.0.2.20", session.reload.ip_address
    assert_equal Session.ip_address_digest("192.0.2.20"), session.ip_address_digest
    assert_equal "192.0.2.21", audit_log.reload.ip_address
    assert_equal "192.0.2.22", impersonation_log.reload.ip_address
    refute_includes session.read_attribute_before_type_cast(:ip_address).to_s, "192.0.2.20"
    refute_includes audit_log.read_attribute_before_type_cast(:ip_address).to_s, "192.0.2.21"
    refute_includes impersonation_log.read_attribute_before_type_cast(:ip_address).to_s, "192.0.2.22"
  end
end
