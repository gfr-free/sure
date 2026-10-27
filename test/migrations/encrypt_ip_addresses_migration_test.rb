# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261027100000_encrypt_ip_addresses")

class EncryptIpAddressesMigrationTest < ActiveSupport::TestCase
  setup do
    skip "Encryption not configured" unless Session.encryption_ready?

    @session = Session.create!(user: users(:family_admin))
    @audit_log = SsoAuditLog.create!(event_type: "login", user: users(:family_admin))
    @impersonation_log = impersonation_sessions(:in_progress).logs.create!(path: "/accounts")

    # Plaintext as written before encryption covered these columns.
    Session.where(id: @session.id).update_all("ip_address = '192.0.2.10', ip_address_digest = NULL")
    SsoAuditLog.where(id: @audit_log.id).update_all("ip_address = '192.0.2.11'")
    ImpersonationSessionLog.where(id: @impersonation_log.id).update_all("ip_address = '192.0.2.12'")
  end

  test "encrypts plaintext IP addresses and backfills the session digest" do
    run_migration(:up)

    assert_equal "192.0.2.10", @session.reload.ip_address
    assert_equal Digest::SHA256.hexdigest("192.0.2.10"), @session.ip_address_digest
    assert_equal "192.0.2.11", @audit_log.reload.ip_address
    assert_equal "192.0.2.12", @impersonation_log.reload.ip_address

    assert_not_equal "192.0.2.10", raw_ip(Session, @session.id)
    assert_not_equal "192.0.2.11", raw_ip(SsoAuditLog, @audit_log.id)
    assert_not_equal "192.0.2.12", raw_ip(ImpersonationSessionLog, @impersonation_log.id)
  end

  test "can be run again without double encrypting" do
    2.times { run_migration(:up) }

    assert_equal "192.0.2.10", @session.reload.ip_address
    assert_equal "192.0.2.11", @audit_log.reload.ip_address
  end

  test "rolling back restores plaintext" do
    run_migration(:up)
    run_migration(:down)

    assert_equal "192.0.2.10", raw_ip(Session, @session.id)
    assert_equal "192.0.2.11", raw_ip(SsoAuditLog, @audit_log.id)
    assert_equal "192.0.2.12", raw_ip(ImpersonationSessionLog, @impersonation_log.id)
  end

  private

    def run_migration(direction)
      ActiveRecord::Migration.suppress_messages do
        EncryptIpAddresses.new.public_send(direction)
      end
    end

    def raw_ip(model, id)
      ActiveRecord::Base.connection.select_value(model.where(id: id).select(:ip_address).to_sql)
    end
end
