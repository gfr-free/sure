require "test_helper"

class Provider::PaperlessTest < ActiveSupport::TestCase
  BASE = "https://paperless.example.com".freeze

  setup do
    Provider::Paperless::HostGuard.stubs(:check!)
    @client = Provider::Paperless.new(base_url: BASE, api_token: "secret-token")
  end

  test "server_info reads the version headers and document count" do
    stub_request(:get, "#{BASE}/api/documents/").with(query: hash_including("page_size" => "1"), headers: { "Authorization" => "Token secret-token" })
      .to_return(status: 200, body: { count: 42, results: [] }.to_json,
                 headers: { "Content-Type" => "application/json", "X-Version" => "2.18.4", "X-Api-Version" => "9" })

    info = @client.server_info

    assert_equal "2.18.4", info[:version]
    assert_equal "9", info[:api_version]
    assert_equal 42, info[:document_count]
  end

  test "search_documents filters by text and dates and resolves correspondent names" do
    stub_request(:get, "#{BASE}/api/documents/")
      .with(query: hash_including("title_content" => "Rewe", "created__gte" => "2026-09-01", "created__lte" => "2026-09-30"))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
        count: 2,
        results: [
          { id: 7, title: "Rewe Kassenbon", created: "2026-09-12", correspondent: 3, mime_type: "application/pdf" },
          { id: 8, title: "Rewe Online", created: "2026-09-14T10:00:00+02:00", created_date: "2026-09-14", correspondent: nil, mime_type: "image/jpeg" }
        ]
      }.to_json)
    stub_request(:get, "#{BASE}/api/correspondents/").with(query: hash_including("id__in" => "3"))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { results: [ { id: 3, name: "REWE Markt" } ] }.to_json)

    documents = @client.search_documents(text: "Rewe", created_from: Date.new(2026, 9, 1), created_to: Date.new(2026, 9, 30))

    assert_equal [ 7, 8 ], documents.map { |d| d[:id] }
    assert_equal "REWE Markt", documents.first[:correspondent_name]
    assert_equal Date.new(2026, 9, 12), documents.first[:created_on]
    assert_nil documents.second[:correspondent_name]
    assert_equal Date.new(2026, 9, 14), documents.second[:created_on]
  end

  test "rejected tokens raise an unauthorized error" do
    stub_request(:get, "#{BASE}/api/documents/5/").with(query: hash_including({}))
      .to_return(status: 401, headers: { "Content-Type" => "application/json" }, body: { detail: "Invalid token." }.to_json)

    error = assert_raises(Provider::Paperless::Error) { @client.document(5) }
    assert_equal :unauthorized, error.error_type
  end

  test "file returns the bytes and content type" do
    stub_request(:get, "#{BASE}/api/documents/5/thumb/")
      .to_return(status: 200, body: "webp-bytes", headers: { "Content-Type" => "image/webp" })

    bytes, content_type = @client.file(5, kind: :thumb)

    assert_equal "webp-bytes", bytes
    assert_equal "image/webp", content_type
  end

  test "file rejects unknown kinds" do
    assert_raises(ArgumentError) { @client.file(5, kind: "metadata") }
  end

  test "unreachable servers raise a connection error" do
    stub_request(:get, "#{BASE}/api/documents/").with(query: hash_including({})).to_raise(Faraday::ConnectionFailed.new("refused"))

    error = assert_raises(Provider::Paperless::Error) { @client.server_info }
    assert_equal :connection_failed, error.error_type
  end

  test "file stops reading once the size limit is exceeded" do
    stub_request(:get, "#{BASE}/api/documents/5/download/")
      .to_return(status: 200, body: "x" * (Provider::Paperless::MAX_FILE_SIZE + 1), headers: { "Content-Type" => "application/pdf" })

    error = assert_raises(Provider::Paperless::Error) { @client.file(5, kind: :download) }
    assert_equal :too_large, error.error_type
  end

  test "requests connect to the address the host guard checked" do
    Provider::Paperless::HostGuard.stubs(:check!).returns("93.184.216.34")
    Net::HTTP.any_instance.expects(:ipaddr=).with("93.184.216.34").at_least_once
    stub_request(:get, "#{BASE}/api/documents/").with(query: hash_including({}))
      .to_return(status: 200, body: { count: 0, results: [] }.to_json, headers: { "Content-Type" => "application/json" })

    @client.server_info
  end
end
