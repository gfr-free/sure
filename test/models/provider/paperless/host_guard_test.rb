require "test_helper"

class Provider::Paperless::HostGuardTest < ActiveSupport::TestCase
  test "blocks private and loopback addresses when private hosts are not allowed" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "false" do
      %w[https://127.0.0.1 https://10.0.0.5 https://192.168.1.20:8000 https://169.254.169.254 https://[::1] https://0.0.0.0
         https://198.18.0.1 https://224.0.0.1 https://240.0.0.1 https://[ff02::1] https://[64:ff9b::c0a8:114] https://[::ffff:10.0.0.1]].each do |url|
        assert_raises(Provider::Paperless::HostGuard::BlockedHost, url) { Provider::Paperless::HostGuard.check!(url) }
      end
    end
  end

  test "blocks host names that resolve to a private address" do
    Resolv.stubs(:getaddresses).with("paperless.lan").returns([ "192.168.1.20" ])

    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "false" do
      assert_raises(Provider::Paperless::HostGuard::BlockedHost) { Provider::Paperless::HostGuard.check!("https://paperless.lan") }
    end
  end

  test "allows public addresses" do
    Resolv.stubs(:getaddresses).with("paperless.example.com").returns([ "93.184.216.34" ])

    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "false" do
      assert_equal "93.184.216.34", Provider::Paperless::HostGuard.check!("https://paperless.example.com"),
                   "returns the checked address so the request can be pinned to it"
    end
  end

  test "requires HTTPS for public hosts so the token is not sent in clear text" do
    Resolv.stubs(:getaddresses).with("paperless.example.com").returns([ "93.184.216.34" ])

    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "false" do
      assert_raises(Provider::Paperless::HostGuard::BlockedHost) { Provider::Paperless::HostGuard.check!("http://paperless.example.com") }
    end
  end

  test "allows a NAT64 address that embeds a public IPv4 address" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "false" do
      assert_equal "64:ff9b::5db8:d822", Provider::Paperless::HostGuard.check!("https://[64:ff9b::5db8:d822]")
    end
  end

  test "allows private addresses when the operator opts in" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "true" do
      assert_equal "192.168.1.20", Provider::Paperless::HostGuard.check!("http://192.168.1.20:8000")

      Resolv.stubs(:getaddresses).with("paperless.lan").returns([ "192.168.1.30" ])
      assert_equal "192.168.1.30", Provider::Paperless::HostGuard.check!("http://paperless.lan:8000"),
                   "pins the resolved address for private hosts as well"
    end
  end

  test "a caller can enforce the checks even where the install allows private hosts" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "true" do
      error = assert_raises(Provider::Paperless::HostGuard::BlockedHost) do
        Provider::Paperless::HostGuard.check!("https://192.168.1.20", allow_private: false)
      end
      assert error.private_network?
    end
  end

  test "rejects URLs that are not http or carry credentials" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "true" do
      assert_raises(Provider::Paperless::HostGuard::BlockedHost) { Provider::Paperless::HostGuard.check!("ftp://paperless.example.com") }
      assert_raises(Provider::Paperless::HostGuard::BlockedHost) { Provider::Paperless::HostGuard.check!("https://user:pass@paperless.example.com") }
    end
  end
end
