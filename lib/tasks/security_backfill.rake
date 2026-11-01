# frozen_string_literal: true

namespace :security do
  # Scope note: this task encrypts values that are still stored as PLAINTEXT.
  # It cannot detect or repair rows that were double-encoded by the pre-fix
  # version of this task (issue #2611): those decrypt "successfully" to a
  # JSON-text String on a json/jsonb column, which is indistinguishable here
  # from a legitimately stored string value, so mutating them automatically
  # would risk mangling valid data. If your instance ran the backfill before
  # the #2611 fix and provider payloads now decrypt to Strings (symptom:
  # zero balances on every provider-linked account after a sync), run the
  # manual recovery script in issue #2611 first, then re-run this task.
  desc "Backfill encryption for sensitive fields (idempotent). Args: batch_size, dry_run"
  task :backfill_encryption, [ :batch_size, :dry_run ] => :environment do |_, args|
    raw_batch = args[:batch_size].presence || ENV["BATCH_SIZE"].presence || "100"
    raw_dry = args[:dry_run].presence || ENV["DRY_RUN"].presence

    batch_size = raw_batch.to_i
    batch_size = 100 if batch_size <= 0

    dry_run = case raw_dry.to_s.strip.downcase
    when "0", "false", "no", "n" then false
    when "1", "true", "yes", "y" then true
    else
      true # Default to dry run for safety
    end

    # Check encryption configuration (use User model which includes Encryptable)
    unless User.encryption_ready?
      puts({
        ok: false,
        error: "encryption_not_configured",
        message: "ActiveRecord encryption is not configured. Set credentials or environment variables."
      }.to_json)
      exit 1
    end

    results = {}
    puts "Starting security backfill (dry_run: #{dry_run}, batch_size: #{batch_size})..."

    # Every model that declares `encrypts`, so providers added later are
    # covered without editing this task.
    Rails.autoloaders.main.eager_load_dir(Rails.root.join("app/models").to_s)
    encrypted_models = ApplicationRecord.descendants
      .reject(&:abstract_class?)
      .select { |model| model == model.base_class && model.encrypted_attributes.present? }
      .sort_by(&:name)

    encrypted_models.each do |model|
      results[model.table_name.to_sym] = backfill_model(model, model.encrypted_attributes.to_a, batch_size, dry_run)
    end

    results[:session_ip_digests] = backfill_session_ip_digests(batch_size, dry_run)

    puts({
      ok: true,
      dry_run: dry_run,
      batch_size: batch_size,
      results: results
    }.to_json)
  end

  def backfill_model(model_class, fields, batch_size, dry_run, &filter_block)
    processed = 0
    pending = 0
    updated = 0
    failed = []

    model_class.order(:id).in_batches(of: batch_size) do |batch|
      batch.each do |record|
        processed += 1

        # Skip if filter block returns false
        next if block_given? && !filter_block.call(record)

        # Only fields still stored as plaintext: rewriting ciphertext on a rerun
        # could also revert a credential a sync rotated in the meantime.
        # Nil-check rather than present?: empty values ({}, [], "") are still
        # plaintext that needs encrypting — present? skips them, leaving data
        # the encrypted getters raise on once keys are live.
        plaintext_fields = fields.reject { |f| record.encrypted_attribute?(f) }
        next unless plaintext_fields.any? { |f| !safe_read_field(record, f).nil? }

        pending += 1
        next if dry_run

        begin
          # Read plaintext values safely
          plaintext_values = {}
          plaintext_fields.each do |field|
            value = safe_read_field(record, field)
            plaintext_values[field] = value unless value.nil?
          end

          next if plaintext_values.empty?

          # Use a temporary instance to encrypt values (avoids triggering
          # validations/callbacks that might read other encrypted fields)
          encryptor = model_class.new
          plaintext_values.each do |field, value|
            encryptor.send("#{field}=", value)
          end

          # Extract the encrypted values from the temporary instance
          encrypted_attrs = {}
          plaintext_values.keys.each do |field|
            encrypted_attrs[field] = encryptor.read_attribute_before_type_cast(field)
          end

          # Write directly to database, bypassing callbacks/validations
          record.update_columns(encrypted_attrs)
          updated += 1
        rescue => e
          failed << { id: record.id, error: e.class.name, message: e.message }
        end
      end
    end

    {
      processed: processed,
      pending: pending,
      updated: updated,
      failed_count: failed.size,
      failed_samples: failed.take(3)
    }
  end

  # Safely read a field value, handling both encrypted and plaintext data.
  # When encryption is configured but the value is plaintext, the getter
  # raises ActiveRecord::Encryption::Errors::Decryption. In this case,
  # we fall back to reading the raw database value. For json/jsonb columns
  # the raw value is the JSON text, not the deserialized Array/Hash the
  # encrypted setter expects, so parse it first — otherwise the backfill
  # encrypts the JSON text itself and the column thereafter decrypts to a
  # String, breaking every consumer of the payload.
  def safe_read_field(record, field)
    record.send(field)
  rescue ActiveRecord::Encryption::Errors::Decryption
    raw = record.read_attribute_before_type_cast(field)
    column = record.class.columns_hash[field.to_s]
    if raw.is_a?(String) && [ :json, :jsonb ].include?(column&.type)
      begin
        JSON.parse(raw)
      rescue JSON::ParserError
        raw
      end
    else
      raw
    end
  end

  # Hashes legacy session IP addresses into ip_address_digest. Encryption of
  # Session columns runs through backfill_model like every other model.
  def backfill_session_ip_digests(batch_size, dry_run)
    processed = 0
    updated = 0
    failed = []

    Session.order(:id).in_batches(of: batch_size) do |batch|
      batch.each do |session|
        processed += 1
        next if dry_run
        next unless session.ip_address.present? && session.ip_address_digest.blank?

        begin
          session.update_columns(ip_address_digest: Digest::SHA256.hexdigest(session.ip_address.to_s))
          updated += 1
        rescue => e
          failed << { id: session.id, error: e.class.name, message: e.message }
        end
      end
    end

    {
      processed: processed,
      updated: updated,
      failed_count: failed.size,
      failed_samples: failed.take(3)
    }
  end
end
