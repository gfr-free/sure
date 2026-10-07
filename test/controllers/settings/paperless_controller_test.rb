require "test_helper"

class Settings::PaperlessControllerTest < ActionDispatch::IntegrationTest
  setup do
    Provider::Paperless::HostGuard.stubs(:check!)
    @family = families(:dylan_family)
  end

  test "shows the settings page" do
    sign_in users(:family_member)

    get settings_paperless_url

    assert_response :success
  end

  test "a member connects their own Paperless account" do
    sign_in users(:family_member)
    Provider::Paperless.any_instance.stubs(:server_info).returns(version: "2.18.4", api_version: "9", document_count: 1)

    assert_difference -> { @family.paperless_connections.where(user: users(:family_member)).count }, 1 do
      patch settings_paperless_url, params: { paperless_connection: { base_url: "https://docs.example.com", api_token: "member-token", verify_ssl: "1" } }
    end

    assert_redirected_to settings_paperless_url
    assert_equal "2.18.4", @family.paperless_connection_for(users(:family_member)).server_version
  end

  test "a blank token keeps the saved token" do
    sign_in users(:family_admin)
    Provider::Paperless.any_instance.stubs(:server_info).returns(version: "2.18.4", api_version: "9", document_count: 1)

    patch settings_paperless_url, params: { paperless_connection: { base_url: "https://other.example.com", api_token: "" } }

    connection = paperless_connections(:admin_connection).reload
    assert_equal "https://other.example.com", connection.base_url
    assert_equal "test-paperless-token", connection.api_token
  end

  test "members cannot change the shared family connection" do
    @family.update!(paperless_connection_mode: "family")
    sign_in users(:family_member)

    assert_no_difference -> { PaperlessConnection.count } do
      patch settings_paperless_url, params: { paperless_connection: { base_url: "https://docs.example.com", api_token: "x" } }
    end

    assert_redirected_to settings_paperless_url
    assert_equal I18n.t("settings.paperless.not_allowed"), flash[:alert]
  end

  test "only admins switch the connection mode" do
    sign_in users(:family_member)
    patch mode_settings_paperless_url, params: { paperless_connection_mode: "family" }
    assert_equal "per_user", @family.reload.paperless_connection_mode

    sign_in users(:family_admin)
    patch mode_settings_paperless_url, params: { paperless_connection_mode: "family" }
    assert_equal "family", @family.reload.paperless_connection_mode
  end

  test "disconnecting removes only the user's own connection" do
    sign_in users(:family_admin)

    assert_difference -> { PaperlessConnection.count }, -1 do
      delete settings_paperless_url
    end
  end
end
