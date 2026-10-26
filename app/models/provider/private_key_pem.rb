# Reads a PEM private key pasted into provider settings. Pastes rarely arrive
# intact: single-line text fields turn line breaks into spaces, JSON exports
# escape them as "\n", Windows adds "\r", and some users paste the key wrapped
# in quotes, indented, or together with its certificate. Only the private key
# block is used, rebuilt with clean line breaks before OpenSSL reads it.
module Provider::PrivateKeyPem
  class Error < StandardError
    attr_reader :reason

    def initialize(message, reason)
      super(message)
      @reason = reason
    end
  end

  KEY_BLOCK = /-----BEGIN ((?:RSA |EC )?PRIVATE KEY)-----(.*?)-----END \1-----/m

  def self.parse(raw)
    match = raw.to_s.match(KEY_BLOCK)

    unless match
      if raw.to_s.include?("-----BEGIN CERTIFICATE-----")
        raise Error.new("found only a certificate, not a private key", :certificate_only)
      end

      raise Error.new("no PEM private key block found", :missing_private_key)
    end

    label = match[1]
    body = match[2].gsub(/\\[rn]|\s/, "")
    pem = "-----BEGIN #{label}-----\n#{body.scan(/.{1,64}/).join("\n")}\n-----END #{label}-----\n"
    # An empty passphrase keeps OpenSSL from prompting on a TTY.
    OpenSSL::PKey.read(pem, "")
  rescue OpenSSL::PKey::PKeyError => e
    raise Error.new("unreadable private key: #{e.message}", :unreadable)
  end
end
