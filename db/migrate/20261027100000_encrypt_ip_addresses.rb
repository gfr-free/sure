# frozen_string_literal: true

# Encrypts IP addresses already stored in plaintext. New rows are encrypted by
# the models; rows written by an older release during a rolling deploy are
# covered by `rake security:backfill_encryption`. Instances without explicit
# encryption keys keep plaintext, matching the models' encryption_ready? guard.
class EncryptIpAddresses < ActiveRecord::Migration[8.1]
  TABLES = %w[sessions sso_audit_logs impersonation_session_logs].freeze
  BATCH_SIZE = 1000

  # Only borrowed for its attribute type; Active Record encryption does not bind
  # ciphertext to a table, so the same type serves all three tables.
  class EncryptedIp < ActiveRecord::Base
    self.table_name = "sessions"
    encrypts :ip_address
  end

  def up
    return unless ActiveRecordEncryptionConfig.explicitly_configured?

    # Keep session lookups by digest working for rows that predate the digest.
    execute <<~SQL
      UPDATE sessions
      SET ip_address_digest = encode(sha256(convert_to(ip_address, 'UTF8')), 'hex')
      WHERE ip_address_digest IS NULL AND ip_address IS NOT NULL AND ip_address <> ''
    SQL

    rewrite_ip_addresses { |raw| encryptor.encrypted?(raw) ? nil : ip_type.serialize(raw) }
  end

  def down
    return unless ActiveRecordEncryptionConfig.explicitly_configured?

    rewrite_ip_addresses { |raw| encryptor.encrypted?(raw) ? ip_type.deserialize(raw) : nil }
  end

  private
    # Yields each stored value and writes back what the block returns (nil skips).
    # Reads and writes raw SQL so the encrypted attribute type never touches a
    # value it was not handed explicitly.
    def rewrite_ip_addresses
      TABLES.each do |table|
        last_id = nil

        loop do
          rows = select_rows(ActiveRecord::Base.sanitize_sql_array([
            "SELECT id, ip_address FROM #{table} WHERE ip_address IS NOT NULL AND (? IS NULL OR id > ?) ORDER BY id LIMIT ?",
            last_id, last_id, BATCH_SIZE
          ]))
          break if rows.empty?

          rows.each do |id, raw|
            value = yield(raw)
            next if value.nil?

            execute ActiveRecord::Base.sanitize_sql_array([ "UPDATE #{table} SET ip_address = ? WHERE id = ?", value, id ])
          end

          last_id = rows.last.first
        end
      end
    end

    def ip_type
      EncryptedIp.type_for_attribute(:ip_address)
    end

    def encryptor
      ActiveRecord::Encryption.encryptor
    end
end
