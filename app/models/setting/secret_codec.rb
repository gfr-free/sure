# frozen_string_literal: true

# Reads and writes the stored form of secret settings (API keys, tokens).
#
# Three formats can be stored, and each one is recognized by its shape alone:
#
# * :active_record - an Active Record Encryption envelope, encrypted with the
#   same keys (and `previous` schemes) as every `encrypts` column.
# * :legacy - a MessageEncryptor value keyed directly from SECRET_KEY_BASE.
#   Declared secret settings were written this way before the switch.
# * :plaintext - anything else, including ENV defaults and values saved
#   before any encryption existed.
module Setting::SecretCodec
  class Undecryptable < StandardError; end

  LEGACY_KEY_SALT = "setting_encryption"
  LEGACY_FORMAT = %r{\A[A-Za-z0-9+/]+={0,2}--[A-Za-z0-9+/]+={0,2}--[A-Za-z0-9+/]+={0,2}\z}
  # MessageEncryptor's default aes-256-gcm writes a 12-byte IV and a 16-byte
  # auth tag, which tells its values apart from plaintext containing "--".
  LEGACY_IV_BYTES = 12
  LEGACY_AUTH_TAG_BYTES = 16
  # `settings.value` of a row that holds no secret (YAML of nil or "").
  EMPTY_STORED_VALUES = [ nil, "", nil.to_yaml, "".to_yaml ].freeze

  LEGACY_ENCRYPTORS = Concurrent::Map.new

  module_function

  def format_of(value)
    return :blank if value.blank?
    return :plaintext unless value.is_a?(String)
    return :active_record if active_record_envelope?(value)
    return :legacy if legacy_envelope?(value)

    :plaintext
  end

  # Returns the plaintext, or raises Undecryptable when no configured key
  # opens the value. Never returns ciphertext.
  # SECRET_KEY_BASE is only looked up for legacy values.
  def decrypt(value, legacy_secret_key_bases: nil)
    case format_of(value)
    when :blank, :plaintext then value
    when :active_record then decrypt_active_record(value).first
    when :legacy then decrypt_legacy(value, legacy_secret_key_bases)
    end
  end

  # Plaintext plus where it came from: :current when the value is already in
  # its final form (Active Record format under the current key), otherwise
  # :plaintext, :legacy or :previous_key.
  def inspect_value(value, legacy_secret_key_bases: nil)
    case format_of(value)
    when :blank then [ value, :blank ]
    when :plaintext then [ value, :plaintext ]
    when :legacy then [ decrypt_legacy(value, legacy_secret_key_bases), :legacy ]
    when :active_record
      plaintext, key = decrypt_active_record(value)
      [ plaintext, key == :current ? :current : :previous_key ]
    end
  end

  def encrypt_active_record(plaintext)
    return plaintext if plaintext.blank?

    ActiveRecord::Encryption.encryptor.encrypt(plaintext.to_s)
  end

  def encrypt_legacy(plaintext, secret_key_base: Rails.application.secret_key_base)
    return plaintext if plaintext.blank?

    legacy_encryptor(secret_key_base).encrypt_and_sign(plaintext)
  end

  def active_record_available?
    ActiveRecord::Encryption.config.primary_key.present? &&
      ActiveRecord::Encryption.config.key_derivation_salt.present?
  rescue ActiveRecord::Encryption::Errors::Configuration
    false
  end

  # Key derivation is slow on purpose, so keep one encryptor per key.
  def legacy_encryptor(secret_key_base)
    LEGACY_ENCRYPTORS.compute_if_absent(Digest::SHA256.hexdigest(secret_key_base.to_s)) do
      key = ActiveSupport::KeyGenerator.new(secret_key_base).generate_key(LEGACY_KEY_SALT, 32)
      ActiveSupport::MessageEncryptor.new(key)
    end
  end

  def legacy_envelope?(value)
    return false unless LEGACY_FORMAT.match?(value)

    _data, iv, auth_tag = value.split("--").map { |part| Base64.strict_decode64(part) }
    iv.bytesize == LEGACY_IV_BYTES && auth_tag.bytesize == LEGACY_AUTH_TAG_BYTES
  rescue ArgumentError
    false
  end

  def active_record_envelope?(value)
    return false unless value.start_with?("{")

    envelope = JSON.parse(value)
    envelope.is_a?(Hash) && envelope.keys.sort == %w[h p] && envelope["p"].is_a?(String) &&
      envelope["h"].is_a?(Hash) && envelope["h"].key?("iv") && envelope["h"].key?("at")
  rescue JSON::ParserError
    false
  end

  def decrypt_active_record(value)
    [ ActiveRecord::Encryption.encryptor.decrypt(value), :current ]
  rescue ActiveRecord::Encryption::Errors::Base
    previous_key_providers.each do |key_provider|
      return [ ActiveRecord::Encryption.encryptor.decrypt(value, key_provider: key_provider), :previous_key ]
    rescue ActiveRecord::Encryption::Errors::Base
      next
    end
    raise Undecryptable, "no configured Active Record Encryption key decrypts the value"
  end

  def previous_key_providers
    ActiveRecord::Encryption.config.previous_schemes.reject(&:deterministic?).filter_map(&:key_provider)
  end

  def decrypt_legacy(value, secret_key_bases = nil)
    secret_key_bases ||= [ Rails.application.secret_key_base ]
    secret_key_bases.compact_blank.uniq.each do |secret_key_base|
      return legacy_encryptor(secret_key_base).decrypt_and_verify(value)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage
      next
    end
    raise Undecryptable, "no given SECRET_KEY_BASE decrypts the value"
  end
end
