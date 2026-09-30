require "test_helper"

class Assistant::Function::SearchFamilyFilesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::SearchFamilyFiles.new(@user)
  end

  test "has correct name" do
    assert_equal "search_family_files", @function.name
  end

  test "has a description" do
    assert_not_empty @function.description
  end

  test "is not in strict mode" do
    assert_not @function.strict_mode?
  end

  test "params_schema requires query" do
    schema = @function.params_schema
    assert_includes schema[:required], "query"
    assert schema[:properties].key?(:query)
  end

  test "generates valid tool definition" do
    definition = @function.to_definition
    assert_equal "search_family_files", definition[:name]
    assert_not_nil definition[:description]
    assert_not_nil definition[:params_schema]
    assert_equal false, definition[:strict]
  end

  test "returns no_documents error when family has no vector store" do
    @user.family.update!(vector_store_id: nil)

    result = @function.call("query" => "tax return")

    assert_equal false, result[:success]
    assert_equal "no_documents", result[:error]
  end

  test "returns provider_not_configured when no adapter is available" do
    @user.family.update!(vector_store_id: "vs_test123")
    VectorStore::Registry.stubs(:adapter).returns(nil)

    result = @function.call("query" => "tax return")

    assert_equal false, result[:success]
    assert_equal "provider_not_configured", result[:error]
  end

  test "drops hits from contract documents the user cannot see" do
    family = @user.family
    family.update!(vector_store_id: "vs_test123")
    member = users(:family_member)
    private_contract = contracts(:liability_insurance)
    shared_contract = contracts(:phone_plan)

    [ [ private_contract, "file-private" ], [ shared_contract, "file-shared" ] ].each do |contract, file_id|
      family_document = family.family_documents.create!(filename: "#{file_id}.pdf", status: "ready", provider_file_id: file_id)
      document = contract.contract_documents.new(family_document: family_document, ai_searchable: true)
      document.file.attach(io: StringIO.new("%PDF-1.4"), filename: "#{file_id}.pdf", content_type: "application/pdf")
      document.save!
    end

    adapter = mock("vector_store_adapter")
    adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: true,
        data: [
          { content: "private policy", filename: "file-private.pdf", score: 0.9, file_id: "file-private" },
          { content: "shared plan", filename: "file-shared.pdf", score: 0.8, file_id: "file-shared" },
          { content: "tax return", filename: "tax.pdf", score: 0.7, file_id: "file-other" }
        ],
        error: nil
      )
    )
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    result = Assistant::Function::SearchFamilyFiles.new(member).call("query" => "policy")

    assert_equal [ "shared plan", "tax return" ], result[:results].map { |r| r[:content] }
  end

  test "drops hits from contract files whose contract document is gone" do
    family = @user.family
    family.update!(vector_store_id: "vs_test123")
    family.family_documents.create!(
      filename: "orphan.pdf", status: "ready", provider_file_id: "file-orphan",
      metadata: { "type" => "contract", "contract_id" => contracts(:phone_plan).id }
    )

    adapter = mock("vector_store_adapter")
    adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: true,
        data: [
          { content: "deleted policy", filename: "orphan.pdf", score: 0.9, file_id: "file-orphan" },
          { content: "tax return", filename: "tax.pdf", score: 0.7, file_id: "file-other" }
        ],
        error: nil
      )
    )
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    result = @function.call("query" => "policy")

    assert_equal [ "tax return" ], result[:results].map { |r| r[:content] }
  end

  test "drops hits from contract documents opted out of search" do
    family = @user.family
    family.update!(vector_store_id: "vs_test123")
    family_document = family.family_documents.create!(
      filename: "opted-out.pdf", status: "ready", provider_file_id: "file-opted-out",
      metadata: { "type" => "contract", "contract_id" => contracts(:phone_plan).id }
    )
    document = contracts(:phone_plan).contract_documents.new(family_document: family_document, ai_searchable: false)
    document.file.attach(io: StringIO.new("%PDF-1.4"), filename: "opted-out.pdf", content_type: "application/pdf")
    document.save!

    adapter = mock("vector_store_adapter")
    adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: true,
        data: [ { content: "opted out", filename: "opted-out.pdf", score: 0.9, file_id: "file-opted-out" } ],
        error: nil
      )
    )
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    result = @function.call("query" => "plan")

    assert_empty result[:results]
  end

  test "drops unknown hits while a contract upload is unfinished" do
    family = @user.family
    family.update!(vector_store_id: "vs_test123")
    family.family_documents.create!(filename: "tax.pdf", status: "ready", provider_file_id: "file-known")
    document = contracts(:phone_plan).contract_documents.new(ai_searchable: true) # uploaded, but no local record yet
    document.file.attach(io: StringIO.new("%PDF-1.4"), filename: "plan.pdf", content_type: "application/pdf")
    document.save!

    adapter = mock("vector_store_adapter")
    adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: true,
        data: [
          { content: "private plan", filename: "plan.pdf", score: 0.9, file_id: "file-orphan" },
          { content: "tax return", filename: "tax.pdf", score: 0.7, file_id: "file-known" }
        ],
        error: nil
      )
    )
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    result = @function.call("query" => "plan")

    assert_equal [ "tax return" ], result[:results].map { |r| r[:content] }
  end

  test "returns search results on success" do
    @user.family.update!(vector_store_id: "vs_test123")

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: true,
        data: [
          { content: "Total income: $85,000", filename: "2024_tax_return.pdf", score: 0.95, file_id: "file-abc" },
          { content: "W-2 wages: $80,000", filename: "2024_tax_return.pdf", score: 0.87, file_id: "file-abc" }
        ],
        error: nil
      )
    )

    VectorStore::Registry.stubs(:adapter).returns(mock_adapter)

    result = @function.call("query" => "What was my total income?")

    assert_equal true, result[:success]
    assert_equal 2, result[:result_count]
    assert_equal "Total income: $85,000", result[:results].first[:content]
    assert_equal "2024_tax_return.pdf", result[:results].first[:filename]
  end

  test "returns empty results message when no matches found" do
    @user.family.update!(vector_store_id: "vs_test123")

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.stubs(:search).returns(
      VectorStore::Response.new(success?: true, data: [], error: nil)
    )

    VectorStore::Registry.stubs(:adapter).returns(mock_adapter)

    result = @function.call("query" => "nonexistent document")

    assert_equal true, result[:success]
    assert_empty result[:results]
  end

  test "handles search failure gracefully" do
    @user.family.update!(vector_store_id: "vs_test123")

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: false,
        data: nil,
        error: VectorStore::Error.new("API rate limit exceeded")
      )
    )

    VectorStore::Registry.stubs(:adapter).returns(mock_adapter)

    result = @function.call("query" => "tax return")

    assert_equal false, result[:success]
    assert_equal "search_failed", result[:error]
  end

  test "caps max_results at 20" do
    @user.family.update!(vector_store_id: "vs_test123")

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.expects(:search).with(
      store_id: "vs_test123",
      query: "test",
      max_results: 20
    ).returns(VectorStore::Response.new(success?: true, data: [], error: nil))

    VectorStore::Registry.stubs(:adapter).returns(mock_adapter)

    @function.call("query" => "test", "max_results" => 50)
  end
end
