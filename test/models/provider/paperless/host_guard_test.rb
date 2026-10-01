require "test_helper"

class Provider::Paperless::HostGuardTest < ActiveSupport::TestCase
  test "blocks private and loopback addresses when private hosts are not allowed" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "false" do
      %w[http://127.0.0.1 http://10.0.0.5 http://192.168.1.20:8000 http://169.254.169.254 http://[::1] http://0.0.0.0].each do |url|
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

  test "allows private addresses when the operator opts in" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "true" do
      assert_nil Provider::Paperless::HostGuard.check!("http://192.168.1.20:8000")
    end
  end

  test "rejects URLs that are not http or carry credentials" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "true" do
      assert_raises(Provider::Paperless::HostGuard::BlockedHost) { Provider::Paperless::HostGuard.check!("ftp://paperless.example.com") }
      assert_raises(Provider::Paperless::HostGuard::BlockedHost) { Provider::Paperless::HostGuard.check!("https://user:pass@paperless.example.com") }
    end
  end
end
