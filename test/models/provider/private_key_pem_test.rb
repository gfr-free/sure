require "test_helper"
require "openssl"

class Provider::PrivateKeyPemTest < ActiveSupport::TestCase
  setup do
    @ec_key = OpenSSL::PKey::EC.generate("prime256v1")
  end

  test "reads SEC1, PKCS#8 and RSA keys" do
    rsa_key = OpenSSL::PKey::RSA.new(2048)

    assert_same_key @ec_key, Provider::PrivateKeyPem.parse(@ec_key.to_pem)
    assert_same_key @ec_key, Provider::PrivateKeyPem.parse(@ec_key.private_to_pem)
    assert_same_key rsa_key, Provider::PrivateKeyPem.parse(rsa_key.to_pem)
    assert_same_key rsa_key, Provider::PrivateKeyPem.parse(rsa_key.private_to_pem)
  end

  test "reads keys whose line breaks were mangled while pasting" do
    pem = @ec_key.to_pem

    {
      "spaces" => pem.gsub("\n", " "),
      "no separators" => pem.delete("\n"),
      "CRLF" => pem.gsub("\n", "\r\n"),
      "escaped LF" => pem.gsub("\n", '\n'),
      "escaped CRLF" => pem.gsub("\n", '\r\n'),
      "quoted" => %("#{pem.gsub("\n", '\n')}"),
      "indented" => pem.lines.map { |line| "    #{line}" }.join,
      "surrounding text" => "Private key:\n#{pem}\nkeep this safe"
    }.each do |variant, raw|
      assert_same_key @ec_key, Provider::PrivateKeyPem.parse(raw), variant
    end
  end

  test "reports a missing key block" do
    error = assert_raises(Provider::PrivateKeyPem::Error) { Provider::PrivateKeyPem.parse("not a key") }
    assert_equal :missing_private_key, error.reason

    error = assert_raises(Provider::PrivateKeyPem::Error) { Provider::PrivateKeyPem.parse(nil) }
    assert_equal :missing_private_key, error.reason
  end

  test "reports a pasted certificate without its key" do
    certificate = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"

    error = assert_raises(Provider::PrivateKeyPem::Error) { Provider::PrivateKeyPem.parse(certificate) }
    assert_equal :certificate_only, error.reason
  end

  test "reports a damaged key body" do
    damaged = @ec_key.to_pem.sub(/\n.{8}/, "\n")

    error = assert_raises(Provider::PrivateKeyPem::Error) { Provider::PrivateKeyPem.parse(damaged) }
    assert_equal :unreadable, error.reason
  end

  test "reports passphrase-protected keys" do
    encrypted_pkcs8 = @ec_key.private_to_pem(OpenSSL::Cipher.new("aes-256-cbc"), "secret")
    encrypted_traditional = OpenSSL::PKey::RSA.new(2048).to_pem(OpenSSL::Cipher.new("aes-256-cbc"), "secret")

    [ encrypted_pkcs8, encrypted_traditional, encrypted_pkcs8.tr("\n", " ") ].each do |pem|
      error = assert_raises(Provider::PrivateKeyPem::Error) { Provider::PrivateKeyPem.parse(pem) }
      assert_equal :encrypted, error.reason
    end
  end

  test "rejects oversized input without scanning it" do
    junk = "-----BEGIN PRIVATE KEY-----" * 1_000

    error = assert_raises(Provider::PrivateKeyPem::Error) { Provider::PrivateKeyPem.parse(junk) }
    assert_equal :too_long, error.reason
  end

  test "stays fast on repeated BEGIN lines without an END line" do
    junk = "-----BEGIN PRIVATE KEY-----" * 590

    elapsed = Benchmark.realtime do
      assert_raises(Provider::PrivateKeyPem::Error) { Provider::PrivateKeyPem.parse(junk) }
    end
    assert_operator elapsed, :<, 0.5
  end

  private

    def assert_same_key(expected, actual, message = nil)
      assert_equal expected.public_to_der, actual.public_to_der, message
    end
end
