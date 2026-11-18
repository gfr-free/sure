# frozen_string_literal: true

require "test_helper"

class Setting::SecretCodecTest < ActiveSupport::TestCase
  setup do
    skip "Encryption not configured" unless Setting::SecretCodec.active_record_available?
  end

  test "recognizes each stored format" do
    assert_equal :blank, Setting::SecretCodec.format_of(nil)
    assert_equal :blank, Setting::SecretCodec.format_of("")
    assert_equal :plaintext, Setting::SecretCodec.format_of("sk-proj-abc123")
    assert_equal :plaintext, Setting::SecretCodec.format_of('{"p":"x"}')
    assert_equal :legacy, Setting::SecretCodec.format_of(Setting::SecretCodec.encrypt_legacy("sk-old"))
    assert_equal :active_record, Setting::SecretCodec.format_of(Setting::SecretCodec.encrypt_active_record("sk-new"))
  end

  test "decrypts every format" do
    assert_equal "sk-plain", Setting::SecretCodec.decrypt("sk-plain")
    assert_equal "sk-old", Setting::SecretCodec.decrypt(Setting::SecretCodec.encrypt_legacy("sk-old"))
    assert_equal "sk-new", Setting::SecretCodec.decrypt(Setting::SecretCodec.encrypt_active_record("sk-new"))
  end

  test "never returns ciphertext it cannot decrypt" do
    other_legacy = Setting::SecretCodec.encrypt_legacy("sk-lost", secret_key_base: "other-" + "a" * 64)
    other_active_record = ActiveRecord::Encryption.encryptor.encrypt("sk-lost", key_provider: other_key_provider)

    assert_raises(Setting::SecretCodec::Undecryptable) { Setting::SecretCodec.decrypt(other_legacy) }
    assert_raises(Setting::SecretCodec::Undecryptable) { Setting::SecretCodec.decrypt(other_active_record) }
  end

  test "reads legacy values with an old SECRET_KEY_BASE when given" do
    old_base = "old-" + "b" * 64
    value = Setting::SecretCodec.encrypt_legacy("sk-old", secret_key_base: old_base)

    assert_equal [ "sk-old", :legacy ],
      Setting::SecretCodec.inspect_value(value, legacy_secret_key_bases: [ Rails.application.secret_key_base, old_base ])
  end

  test "reads values under a previous Active Record key and reports it" do
    provider = other_key_provider
    value = ActiveRecord::Encryption.encryptor.encrypt("sk-rotated", key_provider: provider)
    ActiveRecord::Encryption.config.stubs(:previous_schemes).returns([ ActiveRecord::Encryption::Scheme.new(key_provider: provider) ])

    assert_equal [ "sk-rotated", :previous_key ], Setting::SecretCodec.inspect_value(value)
    assert_equal [ "sk-now", :current ], Setting::SecretCodec.inspect_value(Setting::SecretCodec.encrypt_active_record("sk-now"))
  end

  private

    def other_key_provider
      ActiveRecordEncryptionConfig::DerivedKeyProvider.new(SecureRandom.hex(32), SecureRandom.hex(32))
    end
end
