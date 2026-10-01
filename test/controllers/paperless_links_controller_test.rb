require "test_helper"

class PaperlessLinksControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @connection = paperless_connections(:admin_connection)
  end

  test "streams the file through the link's connection, also for members without their own" do
    link = PaperlessLink.create!(family: @family, linkable: transactions(:one), paperless_connection: @connection, document_id: 7, title: "Rechnung")
    Provider::Paperless.any_instance.expects(:file).with(7, kind: "preview").returns([ "%PDF-1.7", "application/pdf" ])
    sign_in users(:family_member)

    get file_paperless_link_url(link, kind: "preview")

    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_match "inline", response.headers["Content-Disposition"]
    assert_match "rechnung.pdf", response.headers["Content-Disposition"]
  end

  test "unknown content types are always downloaded" do
    link = PaperlessLink.create!(family: @family, linkable: transactions(:one), paperless_connection: @connection, document_id: 7)
    Provider::Paperless.any_instance.stubs(:file).returns([ "<html>", "text/html" ])
    sign_in users(:family_admin)

    get file_paperless_link_url(link, kind: "preview")

    assert_equal "application/octet-stream", response.media_type
    assert_match "attachment", response.headers["Content-Disposition"]
  end

  test "links on accounts the user cannot see are not found" do
    private_entry = create_transaction(account: accounts(:investment), amount: 20)
    link = PaperlessLink.create!(family: @family, linkable: private_entry.transaction, paperless_connection: @connection, document_id: 7)
    Provider::Paperless.any_instance.expects(:file).never
    sign_in users(:family_member)

    get file_paperless_link_url(link, kind: "thumb")

    assert_response :not_found
  end

  test "search thumbnails use the user's own connection" do
    Provider::Paperless.any_instance.expects(:file).with("7", kind: :thumb).returns([ "img", "image/webp" ])
    sign_in users(:family_admin)

    get paperless_document_thumb_url(document_id: 7)

    assert_response :success
    assert_equal "image/webp", response.media_type
  end

  test "search thumbnails need a connection" do
    sign_in users(:family_member)

    get paperless_document_thumb_url(document_id: 7)

    assert_response :not_found
  end
end
