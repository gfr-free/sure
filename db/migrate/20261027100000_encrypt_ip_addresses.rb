# frozen_string_literal: true

# Encrypts IP addresses already stored in plaintext and replaces the unkeyed
# session IP digest (reversible by hashing every IPv4 address) with a keyed one.
# New rows are handled by the models; rows an older release writes during a
# rolling deploy are covered by `rake security:backfill_encryption`. Instances
# without explicit encryption keys keep plaintext, like the models.
class EncryptIpAddresses < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

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

    rewrite_ip_addresses do |raw|
      next if encryptor.encrypted?(raw)

      [ ip_type.serialize(raw), (keyed_digest(raw) if raw.present?) ]
    end
  end

  def down
    return unless ActiveRecordEncryptionConfig.explicitly_configured?

    rewrite_ip_addresses do |raw|
      next unless encryptor.encrypted?(raw)

      plain = ip_type.deserialize(raw)
      [ plain, (Digest::SHA256.hexdigest(plain) if plain.present?) ]
    end
  end

  private
    # Yields each stored value; the block returns [ip_address, session digest]
    # (a nil digest keeps the current one) or nil to skip the row. Talks to the connection directly so values never reach the
    # migration log, and commits per batch so session rows are not held locked
    # while the request path keeps touching them.
    def rewrite_ip_addresses
      TABLES.each do |table|
        rewritten = 0
        last_id = nil

        loop do
          rows = connection.select_rows(sanitize([
            "SELECT id, ip_address FROM #{table} WHERE ip_address IS NOT NULL #{'AND id > ?' if last_id} ORDER BY id LIMIT ?",
            *last_id, BATCH_SIZE
          ]))
          break if rows.empty?

          updates = rows.filter_map do |id, raw|
            values = yield(raw)
            [ id, *values ] if values
          end
          update_batch(table, updates) if updates.any?

          rewritten += updates.size
          last_id = rows.last.first
        end

        say "#{table}: #{rewritten} IP addresses rewritten"
      end
    end

    def update_batch(table, updates)
      digest_set = table == "sessions" ? ", ip_address_digest = COALESCE(v.digest, t.ip_address_digest)" : ""
      values = updates.map { |id, ip, digest| sanitize([ "(CAST(? AS uuid), ?, ?)", id, ip, digest ]) }.join(", ")

      connection.transaction do
        connection.execute(<<~SQL)
          UPDATE #{table} AS t SET ip_address = v.ip#{digest_set}
          FROM (VALUES #{values}) AS v(id, ip, digest)
          WHERE t.id = v.id
        SQL
      end
    end

    def sanitize(sql)
      ActiveRecord::Base.sanitize_sql_array(sql)
    end

    # Must match Session.ip_address_digest; kept inline so later model changes
    # cannot alter what this migration writes.
    def keyed_digest(ip_address)
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key("session_ip_address", 32), ip_address.to_s)
    end

    def ip_type
      EncryptedIp.type_for_attribute(:ip_address)
    end

    def encryptor
      ActiveRecord::Encryption.encryptor
    end
end
