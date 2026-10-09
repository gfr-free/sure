require "test_helper"

class ContractDocumentUnindexJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(vector_store_id: "vs_test123")
    @family_document = @family.family_documents.create!(filename: "policy.pdf", status: "ready", provider_file_id: "file-policy")
  end

  test "removes the file from the document store" do
    adapter = mock("vector_store_adapter")
    adapter.expects(:remove_file).returns(VectorStore::Response.new(success?: true, data: nil, error: nil))
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    ContractDocumentUnindexJob.perform_now(@family_document)

    assert_not FamilyDocument.exists?(@family_document.id)
  end

  test "retries a failed removal" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:remove_file).returns(VectorStore::Response.new(success?: false, data: nil, error: "boom"))
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    assert_enqueued_with(job: ContractDocumentUnindexJob, args: [ @family_document ]) do
      ContractDocumentUnindexJob.perform_now(@family_document)
    end
    assert FamilyDocument.exists?(@family_document.id)
  end

  test "does not retry without a document store" do
    VectorStore::Registry.stubs(:adapter).returns(nil)

    assert_no_enqueued_jobs only: ContractDocumentUnindexJob do
      ContractDocumentUnindexJob.perform_now(@family_document)
    end
  end

  test "does not retry without a family document store" do
    @family.update!(vector_store_id: nil)
    VectorStore::Registry.stubs(:adapter).returns(mock("vector_store_adapter"))

    assert_no_enqueued_jobs only: ContractDocumentUnindexJob do
      ContractDocumentUnindexJob.perform_now(@family_document)
    end
  end

  test "logs and gives up once the retries are used up" do
    adapter = mock("vector_store_adapter")
    adapter.stubs(:remove_file).returns(VectorStore::Response.new(success?: false, data: nil, error: "boom"))
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    assert_difference -> { DebugLogEntry.where(source: "ContractDocumentUnindexJob").count }, 1 do
      perform_enqueued_jobs { ContractDocumentUnindexJob.perform_later(@family_document) }
    end
    assert_performed_jobs 5
  end
end
