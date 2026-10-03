require "test_helper"

class TransactionPaperlessLinksControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @entry = entries(:transaction)
    sign_in users(:family_admin)
  end

  test "search shows matching Paperless documents" do
    Provider::Paperless.any_instance.expects(:search_documents)
      .with(text: "Rewe", created_from: @entry.date - 30, created_to: @entry.date + 30)
      .returns([ { id: 7, title: "Rewe Kassenbon", created_on: @entry.date, correspondent_name: "REWE", mime_type: "application/pdf" } ])

    get new_transaction_paperless_link_url(@entry), params: { text: "Rewe" }

    assert_response :success
    assert_includes response.body, "Rewe Kassenbon"
  end

  test "search errors are shown instead of failing" do
    Provider::Paperless.any_instance.stubs(:search_documents).raises(Provider::Paperless::Error.new("Could not reach Paperless", :connection_failed))

    get new_transaction_paperless_link_url(@entry)

    assert_response :success
    assert_includes response.body, "Could not reach Paperless"
  end

  test "links a document to the transaction" do
    Provider::Paperless.any_instance.stubs(:document).returns(id: 7, title: "Rewe Kassenbon", created_on: @entry.date, correspondent_name: "REWE", mime_type: "application/pdf")

    assert_difference -> { @entry.transaction.paperless_links.count }, 1 do
      post transaction_paperless_links_url(@entry), params: { document_id: 7 }
    end

    assert_equal "Rewe Kassenbon", @entry.transaction.paperless_links.last.title
  end

  test "unlinks a document" do
    link = PaperlessLink.create!(family: @entry.account.family, linkable: @entry.transaction, document_id: 7)

    assert_difference -> { PaperlessLink.count }, -1 do
      delete transaction_paperless_link_url(@entry, link)
    end
  end

  test "without a connection the user is sent to the settings" do
    sign_in users(:family_member)

    get new_transaction_paperless_link_url(@entry)

    assert_redirected_to settings_paperless_url
  end

  test "read-only members cannot link" do
    sign_in users(:family_member)
    credit_card_entry = create_transaction(account: accounts(:credit_card), amount: 20)

    assert_no_difference -> { PaperlessLink.count } do
      post transaction_paperless_links_url(credit_card_entry), params: { document_id: 7 }
    end
  end

  test "transactions on accounts the user cannot see are not found" do
    sign_in users(:family_member)
    private_entry = create_transaction(account: accounts(:investment), amount: 20)

    post transaction_paperless_links_url(private_entry), params: { document_id: 7 }

    assert_response :not_found
  end

  test "search thumbnails stream through the user's connection" do
    Provider::Paperless.any_instance.expects(:file).with("7", kind: :thumb).returns([ "img", "image/webp" ])

    get thumb_transaction_paperless_links_url(@entry, document_id: 7)

    assert_response :success
    assert_equal "image/webp", response.media_type
  end

  test "search thumbnails need a connection" do
    sign_in users(:family_member)

    get thumb_transaction_paperless_links_url(@entry, document_id: 7)

    assert_response :not_found
  end

  test "a shared connection shows search thumbnails only to members who may link" do
    Provider::Paperless::HostGuard.stubs(:check!)
    family = @entry.account.family
    family.paperless_connections.create!(user: nil, base_url: "https://docs.example.com", api_token: "abc")
    family.update!(paperless_connection_mode: "family")
    credit_card_entry = create_transaction(account: accounts(:credit_card), amount: 20)
    Provider::Paperless.any_instance.expects(:file).never
    sign_in users(:family_member)

    get thumb_transaction_paperless_links_url(credit_card_entry, document_id: 7)

    assert_response :redirect
  end

  test "the transaction drawer lists linked documents" do
    PaperlessLink.create!(family: @entry.account.family, linkable: @entry.transaction,
                          paperless_connection: paperless_connections(:admin_connection), document_id: 7, title: "Stromrechnung")

    get transaction_url(@entry)

    assert_response :success
    assert_includes response.body, "Stromrechnung"
    assert_includes response.body, new_transaction_paperless_link_path(@entry)
  end
end
