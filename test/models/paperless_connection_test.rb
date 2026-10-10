require "test_helper"

class PaperlessConnectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
  end

  test "normalizes the base url and stores the token" do
    Provider::Paperless::HostGuard.stubs(:check!)
    connection = @family.paperless_connections.create!(user: @member, base_url: " https://docs.example.com/ ", api_token: "abc")

    assert_equal "https://docs.example.com", connection.base_url
    assert_equal "abc", connection.reload.api_token
  end

  test "rejects a base url the host guard blocks" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "false" do
      connection = @family.paperless_connections.new(user: @member, base_url: "http://127.0.0.1:8000", api_token: "abc")

      assert_not connection.valid?
      assert connection.errors[:base_url].any?
    end
  end

  test "rejects a user from another family" do
    Provider::Paperless::HostGuard.stubs(:check!)
    connection = @family.paperless_connections.new(user: users(:empty), base_url: "https://docs.example.com", api_token: "abc")

    assert_not connection.valid?
    assert connection.errors[:user].any?
  end

  test "per user mode resolves each member's own connection" do
    assert_equal paperless_connections(:admin_connection), @family.paperless_connection_for(@admin)
    assert_nil @family.paperless_connection_for(@member)
    assert @family.can_manage_paperless_connection?(@member)
  end

  test "family mode resolves the shared connection for everyone and only admins manage it" do
    Provider::Paperless::HostGuard.stubs(:check!)
    shared = @family.paperless_connections.create!(user: nil, base_url: "https://docs.example.com", api_token: "abc")
    @family.update!(paperless_connection_mode: "family")

    assert_equal shared, @family.paperless_connection_for(@admin)
    assert_equal shared, @family.paperless_connection_for(@member)
    assert @family.can_manage_paperless_connection?(@admin)
    assert_not @family.can_manage_paperless_connection?(@member)
  end

  test "verify! records the server version or the error" do
    connection = paperless_connections(:admin_connection)
    Provider::Paperless.any_instance.stubs(:server_info).returns(version: "2.18.4", api_version: "9", document_count: 3)

    assert connection.verify!
    assert_equal "2.18.4", connection.reload.server_version
    assert_nil connection.last_error

    Provider::Paperless.any_instance.stubs(:server_info).raises(Provider::Paperless::Error.new("Paperless rejected the API token", :unauthorized))

    assert_not connection.verify!
    assert_equal "Paperless rejected the API token", connection.reload.last_error
  end

  test "removing a connection keeps the links" do
    link = PaperlessLink.create!(family: @family, linkable: transactions(:one), paperless_connection: paperless_connections(:admin_connection), document_id: 9, title: "Beleg")

    paperless_connections(:admin_connection).destroy!

    assert_nil link.reload.paperless_connection
    assert_equal "Beleg", link.title
  end

  test "changing the address detaches existing links" do
    Provider::Paperless::HostGuard.stubs(:check!)
    connection = paperless_connections(:admin_connection)
    link = PaperlessLink.create!(family: @family, linkable: transactions(:one), paperless_connection: connection, document_id: 9)

    connection.update!(verify_ssl: false)
    assert_equal connection, link.reload.paperless_connection

    connection.update!(base_url: "https://new-server.example.com")
    assert_nil link.reload.paperless_connection
  end

  test "only admins can connect a server on the local network" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "true" do
      member_connection = @family.paperless_connections.new(user: @member, base_url: "http://192.168.1.20:8000", api_token: "abc")
      assert_not member_connection.valid?
      assert_includes member_connection.errors[:base_url], I18n.t("paperless.host_guard.admin_only")

      admin_connection = paperless_connections(:admin_connection)
      admin_connection.base_url = "http://192.168.1.20:8000"
      assert admin_connection.valid?

      shared = @family.paperless_connections.new(user: nil, base_url: "http://192.168.1.21:8000", api_token: "abc")
      assert shared.valid?
    end
  end

  test "a member can use the local server an admin already connected" do
    paperless_connections(:admin_connection).update_column(:base_url, "http://192.168.1.20:8000")

    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "true" do
      same_server = @family.paperless_connections.new(user: @member, base_url: "http://192.168.1.20:8000", api_token: "abc")
      assert same_server.valid?

      other_port = @family.paperless_connections.new(user: @member, base_url: "http://192.168.1.20:22", api_token: "abc")
      assert_not other_port.valid?
    end
  end

  test "a member's client checks every request against private addresses" do
    with_env_overrides PAPERLESS_ALLOW_PRIVATE_HOSTS: "true" do
      connection = @family.paperless_connections.new(user: @member, base_url: "http://192.168.1.20:8000", api_token: "abc")

      error = assert_raises(Provider::Paperless::Error) { connection.client.server_info }
      assert_equal :blocked_host, error.error_type
    end
  end
end
