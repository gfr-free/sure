# frozen_string_literal: true

require "test_helper"
require "rake"

# The settings part of security:backfill_encryption and its way back,
# security:downgrade_setting_secrets.
class SecuritySettingSecretsBackfillTest < ActiveSupport::TestCase
  OLD_SECRET_KEY_BASE = "old-secret-key-base-#{"h" * 64}"

  setup do
    skip "Encryption not configured" unless Setting::SecretCodec.active_record_available?
    Rails.application.load_tasks unless Rake::Task.task_defined?("security:backfill_encryption")
    Provider::Factory.ensure_adapters_loaded
    Setting.where(var: Setting.secret_setting_vars).delete_all
    Setting.settings_secrets_format = Setting::SECRETS_FORMAT_LEGACY
  end

  teardown do
    Setting.clear_cache
  end

  test "converts plaintext, legacy and dynamic secrets and switches new writes" do
    store_raw("openai_access_token", legacy("sk-legacy"))
    store_raw("anthropic_access_token", "sk-plain")
    store_raw("dynamic:plaid_secret", "plaid-plain")

    result = run_task("security:backfill_encryption", "500", "0")["results"]["settings_secrets"]

    assert_equal 0, result["failed_count"]
    assert_equal 3, result["updated"]
    assert_equal Setting::SECRETS_FORMAT_ACTIVE_RECORD, Setting.settings_secrets_format
    %w[openai_access_token anthropic_access_token dynamic:plaid_secret].each do |var|
      assert_equal :active_record, Setting::SecretCodec.format_of(Setting.find_by(var: var).value), var
    end
    assert_equal "sk-legacy", Setting.openai_access_token
    assert_equal "sk-plain", Setting.anthropic_access_token
    assert_equal "plaid-plain", Setting["plaid_secret"]
  end

  test "a dry run reports without writing or switching" do
    value = legacy("sk-legacy")
    store_raw("openai_access_token", value)

    result = run_task("security:backfill_encryption", "500", "1")["results"]["settings_secrets"]

    assert_equal 1, result["legacy"]
    assert_equal value, Setting.find_by(var: "openai_access_token").value
    assert_equal Setting::SECRETS_FORMAT_LEGACY, Setting.settings_secrets_format
  end

  test "a second run changes nothing" do
    store_raw("openai_access_token", "sk-plain")
    run_task("security:backfill_encryption", "500", "0")
    stored = Setting.find_by(var: "openai_access_token").value

    result = run_task("security:backfill_encryption", "500", "0")["results"]["settings_secrets"]

    assert_equal 0, result["updated"]
    assert_equal 1, result["current"]
    assert_equal stored, Setting.find_by(var: "openai_access_token").value
  end

  test "reads values saved under an old SECRET_KEY_BASE when OLD_SECRET_KEY_BASE is set" do
    store_raw("openai_access_token", legacy("sk-old", OLD_SECRET_KEY_BASE))

    report = with_env_overrides("OLD_SECRET_KEY_BASE" => OLD_SECRET_KEY_BASE) do
      run_task("security:backfill_encryption", "500", "0")
    end

    assert_equal 0, report["results"]["settings_secrets"]["failed_count"]
    assert_equal "sk-old", Setting.openai_access_token
  end

  test "reads legacy values with the SECRET_KEY_BASE given for the Active Record rotation" do
    store_raw("openai_access_token", legacy("sk-old", OLD_SECRET_KEY_BASE))

    report = with_env_overrides(ActiveRecordEncryptionConfig::PREVIOUS_SECRET_KEY_BASE_ENV => OLD_SECRET_KEY_BASE) do
      Setting::SecretCodec.stubs(:previous_key_providers).returns([])
      run_task("security:backfill_encryption", "500", "0")
    end

    assert_equal 0, report["results"]["settings_secrets"]["failed_count"]
    assert_equal "sk-old", Setting.openai_access_token
  end

  test "leaves a value no key decrypts untouched, fails the run and does not switch" do
    lost = legacy("sk-lost", OLD_SECRET_KEY_BASE)
    store_raw("openai_access_token", lost)
    store_raw("anthropic_access_token", "sk-plain")

    report = run_task("security:backfill_encryption", "500", "0")
    result = report["results"]["settings_secrets"]

    assert_not report["ok"]
    assert_equal 1, result["failed_count"]
    assert_equal "not_decryptable", result["failed_samples"].first["error"]
    assert_equal "openai_access_token", result["failed_samples"].first["var"]
    assert_not_includes report.to_json, "sk-lost"
    assert_equal lost, Setting.find_by(var: "openai_access_token").value
    assert_equal Setting::SECRETS_FORMAT_LEGACY, Setting.settings_secrets_format
  end

  test "does not overwrite a value that changed while the task ran" do
    store_raw("openai_access_token", "sk-plain")
    original = Setting::SecretCodec.method(:encrypt_active_record)
    # An admin saves a new key between the task's read and its write.
    Setting::SecretCodec.define_singleton_method(:encrypt_active_record) do |value|
      Setting.where(var: "openai_access_token").update_all(value: "sk-from-form".to_yaml)
      original.call(value)
    end

    result = run_task("security:backfill_encryption", "500", "0")["results"]["settings_secrets"]

    assert_equal "changed_concurrently", result["failed_samples"].first["error"]
    assert_equal "sk-from-form", Setting.find_by(var: "openai_access_token").value
    assert_equal Setting::SECRETS_FORMAT_LEGACY, Setting.settings_secrets_format
  ensure
    Setting::SecretCodec.define_singleton_method(:encrypt_active_record, original) if original
  end

  test "does not write a value whose new ciphertext does not decrypt to the original" do
    store_raw("openai_access_token", "sk-plain")
    Setting::SecretCodec.stubs(:encrypt_active_record).returns(Setting::SecretCodec.encrypt_legacy("something-else"))

    result = run_task("security:backfill_encryption", "500", "0")["results"]["settings_secrets"]

    assert_equal 1, result["failed_count"]
    assert_equal "verification_failed", result["failed_samples"].first["error"]
    assert_equal 1, result["processed"]
    assert_equal "sk-plain", Setting.find_by(var: "openai_access_token").value
  end

  test "reports old Lunch Flow credentials without touching them" do
    store_raw("dynamic:lunchflow_api_key", "lf-plain")

    result = run_task("security:backfill_encryption", "500", "0")["results"]["settings_secrets"]

    assert_equal [ "dynamic:lunchflow_api_key" ], result["unused_plaintext_settings"]
    assert_equal "lf-plain", Setting.find_by(var: "dynamic:lunchflow_api_key").value
  end

  test "downgrade writes the previous formats back and switches back" do
    store_raw("openai_access_token", legacy("sk-legacy"))
    store_raw("dynamic:plaid_secret", "plaid-plain")
    run_task("security:backfill_encryption", "500", "0")

    report = run_task("security:downgrade_setting_secrets", "0")

    assert report["ok"]
    assert_equal Setting::SECRETS_FORMAT_LEGACY, Setting.settings_secrets_format
    assert_equal :legacy, Setting::SecretCodec.format_of(Setting.find_by(var: "openai_access_token").value)
    assert_equal "plaid-plain", Setting.find_by(var: "dynamic:plaid_secret").value
    assert_equal "sk-legacy", Setting.openai_access_token
  end

  test "downgrade defaults to a dry run" do
    store_raw("openai_access_token", Setting::SecretCodec.encrypt_active_record("sk-ar"))

    report = run_task("security:downgrade_setting_secrets")

    assert report["dry_run"]
    assert_equal "would_downgrade", report["results"]["openai_access_token"]
    assert_equal :active_record, Setting::SecretCodec.format_of(Setting.find_by(var: "openai_access_token").value)
  end

  private

    def legacy(plaintext, secret_key_base = Rails.application.secret_key_base)
      Setting::SecretCodec.encrypt_legacy(plaintext, secret_key_base: secret_key_base)
    end

    def store_raw(var, value)
      Setting.find_or_initialize_by(var: var).update!(value: value)
      Setting.clear_cache
    end

    # Runs a task like an operator would and returns its JSON report. The
    # tasks exit 1 on failures, which must not end the test process.
    def run_task(name, *args)
      task = Rake::Task[name]
      task.reenable
      output, = capture_io do
        task.invoke(*args)
      rescue SystemExit
        nil
      end
      JSON.parse(output.lines.last)
    end
end
