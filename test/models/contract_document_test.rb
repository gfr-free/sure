require "test_helper"

class ContractDocumentTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @contract = contracts(:liability_insurance)
    @family = @contract.family
  end

  test "accepts PDFs and images only" do
    document = build_document("policy.txt", "text/plain", content: "just some text")

    assert_not document.valid?
    assert document.errors.key?(:file)
  end

  test "opting in uploads to the document store with the contract id, opting out removes it" do
    document = build_document("policy.pdf", "application/pdf")
    document.save!
    family_document = @family.family_documents.create!(filename: "policy.pdf", status: "ready", provider_file_id: "file-1")

    Family.any_instance.expects(:upload_document).with do |file_content:, filename:, metadata:|
      filename == "policy.pdf" && metadata["contract_id"] == @contract.id
    end.returns(family_document)

    document.update!(ai_searchable: true)
    document.sync_search_index!
    assert_equal family_document, document.reload.family_document

    Family.any_instance.expects(:remove_document).with(family_document).returns(true)
    document.update!(ai_searchable: false)
    document.sync_search_index!
    assert_nil document.reload.family_document_id
  end

  test "an upload that finishes after the opt-out removes its copy again" do
    document = build_document("policy.pdf", "application/pdf")
    document.ai_searchable = true
    document.save!
    family_document = @family.family_documents.create!(filename: "policy.pdf", status: "ready", provider_file_id: "file-3")
    Family.any_instance.stubs(:upload_document).with do |**|
      ContractDocument.where(id: document.id).update_all(ai_searchable: false) # opted out or moved meanwhile
      true
    end.returns(family_document)

    assert_enqueued_with(job: ContractDocumentUnindexJob, args: [ family_document ]) do
      assert document.sync_search_index!
    end
    assert_nil document.reload.family_document_id
  end

  test "a failed opt-out removal is retried" do
    document = build_document("policy.pdf", "application/pdf")
    family_document = @family.family_documents.create!(filename: "policy.pdf", status: "ready", provider_file_id: "file-4")
    document.family_document = family_document
    document.save!
    Family.any_instance.stubs(:remove_document).returns(false)

    assert_enqueued_with(job: ContractDocumentIndexJob, args: [ document ]) do
      ContractDocumentIndexJob.perform_now(document)
    end
    assert_equal family_document, document.reload.family_document
  end

  test "a failed opt-in upload is retried and logged once the retries run out" do
    document = build_document("policy.pdf", "application/pdf")
    document.ai_searchable = true
    document.save!
    VectorStore.stubs(:adapter).returns(mock("adapter"))
    Family.any_instance.stubs(:upload_document).returns(nil)

    assert_not document.sync_search_index!
    assert_enqueued_with(job: ContractDocumentIndexJob, args: [ document ]) do
      ContractDocumentIndexJob.perform_now(document)
    end

    assert_difference -> { DebugLogEntry.where(source: "ContractDocumentIndexJob").count }, 1 do
      job = ContractDocumentIndexJob.new(document)
      job.exception_executions = { "[ContractDocumentIndexJob::SyncFailed]" => 4 }
      job.perform_now
    end
    entry = DebugLogEntry.where(source: "ContractDocumentIndexJob").last
    assert_equal "upload", entry.metadata["action"]
    assert document.reload.ai_searchable?
    assert_nil document.family_document_id
  end

  test "without a document store an opt-in has nothing to retry" do
    document = build_document("policy.pdf", "application/pdf")
    document.ai_searchable = true
    document.save!
    VectorStore.stubs(:adapter).returns(nil)
    Family.any_instance.stubs(:upload_document).returns(nil)

    assert document.sync_search_index!
  end

  test "deleting an indexed document removes its copy from the store" do
    document = build_document("policy.pdf", "application/pdf")
    family_document = @family.family_documents.create!(filename: "policy.pdf", status: "ready", provider_file_id: "file-2")
    document.family_document = family_document
    document.save!

    assert_enqueued_with(job: ContractDocumentUnindexJob) do
      document.destroy!
    end
  end

  private

    def build_document(filename, content_type, content: "%PDF-1.4")
      document = @contract.contract_documents.new
      document.file.attach(io: StringIO.new(content), filename: filename, content_type: content_type)
      document
    end
end
