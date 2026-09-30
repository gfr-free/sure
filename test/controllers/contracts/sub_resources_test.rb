require "test_helper"

class Contracts::SubResourcesTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @admin = users(:family_admin)
    @member = users(:family_member)
    [ @admin, @member ].each { |user| user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true)) }
    @contract = contracts(:phone_plan)
    ensure_tailwind_build
  end

  test "ending a contract ends its linked bills on the same date" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @contract)
    ends_on = 2.months.from_now.to_date

    get new_contract_ending_url(@contract)
    assert_response :success

    post contract_ending_url(@contract), params: { ending: { ends_on: ends_on.iso8601 } }

    assert_redirected_to contract_url(@contract)
    assert @contract.reload.ended?
    assert_equal ends_on, @contract.ends_on
    assert_equal ends_on, bill.reload.end_on
  end

  test "a read-write share ends only the bills it may change" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @contract, account: accounts(:loan)) # an account not shared with the member
    @contract.contract_shares.find_by!(user: @member).update!(permission: "read_write")
    sign_in @member

    post contract_ending_url(@contract), params: { ending: { ends_on: 2.months.from_now.to_date.iso8601 } }

    assert @contract.reload.ended?
    assert bill.reload.ends_never?
  end

  test "the ending dialog mentions only bills the user may end" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @contract, account: accounts(:loan)) # an account not shared with the member
    @contract.contract_shares.find_by!(user: @member).update!(permission: "read_write")
    sign_in @member

    get new_contract_ending_url(@contract)

    assert_response :success
    assert_not_includes response.body, I18n.t("contracts.endings.new.bills_hint")
  end

  test "ending needs a date and cannot end before the start" do
    post contract_ending_url(@contract), params: { ending: { ends_on: "" } }
    assert_response :unprocessable_entity

    post contract_ending_url(@contract), params: { ending: { ends_on: (@contract.started_on - 1.day).iso8601 } }
    assert_response :unprocessable_entity

    assert @contract.reload.active?
  end

  test "removing the end reopens the contract and its bills" do
    bill = recurring_transactions(:netflix_subscription)
    bill.update!(contract: @contract)
    @contract.end_contract!(on: 2.months.from_now.to_date)

    delete contract_ending_url(@contract)

    assert_redirected_to contract_url(@contract)
    assert @contract.reload.active?
    assert_nil @contract.ends_on
    assert bill.reload.ends_never?
  end

  test "read-only shares cannot end a contract" do
    sign_in @member

    post contract_ending_url(@contract), params: { ending: { ends_on: Date.current.iso8601 } }

    assert_response :not_found
    assert @contract.reload.active?
  end

  test "owner shares and unshares" do
    patch contract_sharing_url(@contract), params: {
      sharing: { members: { "0" => { user_id: @member.id, shared: "1", permission: "read_write" } } }
    }

    assert_redirected_to contract_url(@contract)
    assert_equal "read_write", @contract.contract_shares.find_by(user: @member).permission

    patch contract_sharing_url(@contract), params: {
      sharing: { members: { "0" => { user_id: @member.id, shared: "0" } } }
    }

    assert_not @contract.contract_shares.exists?(user: @member)
  end

  test "sharing ignores users outside the family" do
    patch contract_sharing_url(@contract), params: {
      sharing: { members: { "0" => { user_id: users(:empty).id, shared: "1", permission: "full_control" } } }
    }

    assert_not @contract.contract_shares.exists?(user: users(:empty))
  end

  test "only managers can open the sharing dialog" do
    sign_in @member

    get contract_sharing_url(@contract)

    assert_response :not_found
  end

  test "uploads, serves and deletes documents" do
    file = fixture_file_upload("test.txt", "application/pdf")

    assert_difference -> { @contract.contract_documents.count }, 1 do
      post contract_documents_url(@contract), params: { contract_document: { files: [ file ] } }
    end
    assert_redirected_to contract_url(@contract)

    document = @contract.contract_documents.last
    get contract_document_url(@contract, document)
    assert_response :redirect

    delete contract_document_url(@contract, document)
    assert_not ContractDocument.exists?(document.id)
  end

  test "rejects unsupported document types" do
    file = fixture_file_upload("test.txt", "text/plain")

    assert_no_difference -> { ContractDocument.count } do
      post contract_documents_url(@contract), params: { contract_document: { files: [ file ] } }
    end
    assert flash[:alert].present?
  end

  test "document search opt-in needs the assistant enabled" do
    document = @contract.contract_documents.new
    document.file.attach(io: StringIO.new("%PDF-1.4"), filename: "policy.pdf", content_type: "application/pdf")
    document.save!
    @admin.update!(ai_enabled: false)

    patch contract_document_url(@contract, document), params: { contract_document: { ai_searchable: "1" } }

    assert_not document.reload.ai_searchable?
    assert flash[:alert].present?
  end

  test "document search opt-in queues indexing" do
    document = @contract.contract_documents.new
    document.file.attach(io: StringIO.new("%PDF-1.4"), filename: "policy.pdf", content_type: "application/pdf")
    document.save!
    User.any_instance.stubs(:ai_enabled?).returns(true)

    assert_enqueued_with(job: ContractDocumentIndexJob) do
      patch contract_document_url(@contract, document), params: { contract_document: { ai_searchable: "1" } }
    end

    assert document.reload.ai_searchable?
  end

  test "read-only shares can view documents but not upload" do
    document = @contract.contract_documents.new
    document.file.attach(io: StringIO.new("%PDF-1.4"), filename: "policy.pdf", content_type: "application/pdf")
    document.save!
    sign_in @member

    get contract_document_url(@contract, document)
    assert_response :redirect

    post contract_documents_url(@contract), params: { contract_document: { files: [ fixture_file_upload("test.txt", "application/pdf") ] } }
    assert_response :not_found
  end
end
