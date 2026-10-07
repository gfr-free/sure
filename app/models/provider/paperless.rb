# Client for the Paperless-ngx REST API (https://docs.paperless-ngx.com/api/).
# Each connection has its own base URL and token, so this is a plain client
# rather than a registered provider concept.
class Provider::Paperless
  class Error < Provider::Error
    attr_reader :error_type

    def initialize(message, error_type = :request_failed)
      super(message)
      @error_type = error_type
    end
  end

  FILE_KINDS = %w[thumb preview download].freeze
  MAX_FILE_SIZE = 50.megabytes
  DOCUMENT_FIELDS = "id,title,created,created_date,correspondent,mime_type,original_file_name".freeze
  DEFAULT_PAGE_SIZE = 20

  def initialize(base_url:, api_token:, verify_ssl: true, allow_private_hosts: false)
    @base_url = base_url
    @api_token = api_token
    @verify_ssl = verify_ssl
    @allow_private_hosts = allow_private_hosts
  end

  # Paperless answers every authenticated request with its version in X-Version.
  def server_info
    response = get("/api/documents/", page_size: 1, fields: "id")
    {
      version: response.headers["x-version"],
      api_version: response.headers["x-api-version"],
      document_count: response.body["count"].to_i
    }
  end

  # `text` searches title and content (substring match, works on all Paperless 2.x
  # versions). Dates filter on the document's created date.
  def search_documents(text: nil, created_from: nil, created_to: nil, page_size: DEFAULT_PAGE_SIZE)
    params = { page_size: page_size, ordering: "-created", fields: DOCUMENT_FIELDS }
    params[:title_content] = text if text.present?
    params[:created__gte] = created_from.iso8601 if created_from
    params[:created__lte] = created_to.iso8601 if created_to

    results = Array(get("/api/documents/", params).body["results"])
    names = correspondent_names(results.filter_map { |doc| doc["correspondent"] })
    results.map { |doc| normalize_document(doc, names) }
  end

  def document(id)
    doc = get("/api/documents/#{Integer(id.to_s, 10)}/", fields: DOCUMENT_FIELDS).body
    normalize_document(doc, correspondent_names([ doc["correspondent"] ].compact))
  end

  # Returns [bytes, content_type]. Paperless renders thumbnails as WebP or PNG and
  # serves the archived PDF for preview/download when one exists.
  def file(id, kind:)
    kind = kind.to_s
    raise ArgumentError, "unknown file kind #{kind}" unless FILE_KINDS.include?(kind)

    body = +""
    response = request(:get, "/api/documents/#{Integer(id.to_s, 10)}/#{kind}/", {}, raw: true) do |req|
      # Stream the body so an oversized file is rejected before it fills memory.
      req.options.on_data = proc do |chunk, received_bytes|
        raise Error.new("Paperless file is too large", :too_large) if received_bytes > MAX_FILE_SIZE

        body << chunk
      end
    end

    [ body, response.headers["content-type"].to_s.split(";").first ]
  end

  private
    attr_reader :base_url, :api_token, :verify_ssl, :allow_private_hosts

    def correspondent_names(ids)
      ids = ids.uniq
      return {} if ids.empty?

      body = get("/api/correspondents/", id__in: ids.join(","), page_size: ids.size, fields: "id,name").body
      Array(body["results"]).to_h { |c| [ c["id"], c["name"] ] }
    end

    # Paperless API v9 turned `created` into a date; older versions send a
    # datetime plus `created_date`. Both are accepted.
    def normalize_document(doc, correspondent_names)
      {
        id: doc["id"],
        title: doc["title"],
        created_on: parse_date(doc["created_date"] || doc["created"]),
        correspondent_name: correspondent_names[doc["correspondent"]],
        mime_type: doc["mime_type"],
        original_file_name: doc["original_file_name"]
      }
    end

    def parse_date(value)
      Date.parse(value.to_s[0, 10]) if value.present?
    rescue Date::Error
      nil
    end

    def get(path, params = {})
      request(:get, path, params)
    end

    def request(method, path, params, raw: false, &block)
      pinned_ip = HostGuard.check!(base_url, allow_private: allow_private_hosts)

      response = connection(raw: raw, pinned_ip: pinned_ip).public_send(method, path, params, &block)
      handle_status!(response)
      response
    rescue HostGuard::BlockedHost => e
      raise Error.new(e.reason, :blocked_host)
    rescue Faraday::SSLError => e
      raise Error.new("SSL error: #{e.message}", :ssl_error)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise Error.new("Could not reach Paperless: #{e.message}", :connection_failed)
    rescue Faraday::ParsingError
      raise Error.new("Paperless sent an unexpected response", :invalid_response)
    end

    def handle_status!(response)
      case response.status
      when 200..299 then nil
      when 401, 403 then raise Error.new("Paperless rejected the API token", :unauthorized)
      when 404 then raise Error.new("Document not found in Paperless", :not_found)
      else raise Error.new("Paperless answered with HTTP #{response.status}", :request_failed)
      end
    end

    # When the host guard resolved the host, connect to exactly that address so a
    # second DNS answer cannot point the request somewhere else (DNS rebinding).
    # TLS still verifies against the host name.
    def connection(raw:, pinned_ip:)
      Faraday.new(url: base_url, ssl: { verify: verify_ssl }, request: { open_timeout: 5, timeout: 20 }) do |f|
        f.headers["Authorization"] = "Token #{api_token}"
        f.headers["Accept"] = "application/json"
        f.response :json, content_type: /\bjson$/ unless raw
        f.adapter :net_http do |http|
          http.ipaddr = pinned_ip if pinned_ip
        end
      end
    end
end
