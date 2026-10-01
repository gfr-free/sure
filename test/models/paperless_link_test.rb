require "test_helper"

class PaperlessLinkTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @connection = paperless_connections(:admin_connection)
  end

  test "link! caches the document details from Paperless" do
    Provider::Paperless.any_instance.expects(:document).with("12").returns(
      id: 12, title: "Stromrechnung", created_on: Date.new(2026, 9, 1), correspondent_name: "Stadtwerke", mime_type: "application/pdf"
    )

    link = PaperlessLink.link!(linkable: transactions(:one), connection: @connection, document_id: "12", user: users(:family_admin))

    assert_equal 12, link.document_id
    assert_equal "Stromrechnung", link.title
    assert_equal "Stadtwerke", link.correspondent_name
    assert_equal users(:family_admin), link.created_by
  end

  test "a document can only be linked once to the same record" do
    PaperlessLink.create!(family: @family, linkable: transactions(:one), paperless_connection: @connection, document_id: 5)

    duplicate = PaperlessLink.new(family: @family, linkable: transactions(:one), paperless_connection: @connection, document_id: 5)
    assert_not duplicate.valid?
  end

  test "the linked record must belong to the same family" do
    link = PaperlessLink.new(family: families(:empty), linkable: transactions(:one), document_id: 5)

    assert_not link.valid?
    assert link.errors[:linkable].any?
  end

  test "visibility follows access to the transaction's account" do
    shared = PaperlessLink.create!(family: @family, linkable: transactions(:one), paperless_connection: @connection, document_id: 5)
    assert shared.visible_to?(users(:family_admin))
    assert shared.visible_to?(users(:family_member)), "depository is shared with the member"

    private_entry = create_transaction(account: accounts(:investment), amount: 10)
    private_link = PaperlessLink.create!(family: @family, linkable: private_entry.transaction, paperless_connection: @connection, document_id: 6)
    assert private_link.visible_to?(users(:family_admin))
    assert_not private_link.visible_to?(users(:family_member))
  end

  test "file fails clearly when the connection was removed" do
    link = PaperlessLink.create!(family: @family, linkable: transactions(:one), document_id: 5)

    error = assert_raises(Provider::Paperless::Error) { link.file("thumb") }
    assert_equal :not_connected, error.error_type
  end
end
