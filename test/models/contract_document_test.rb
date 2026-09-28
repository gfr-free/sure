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
