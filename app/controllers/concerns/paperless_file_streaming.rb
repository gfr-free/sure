module PaperlessFileStreaming
  extend ActiveSupport::Concern

  private
    # Only PDFs and images are shown inline; anything else is sent as a generic
    # download so a Paperless file can never render as HTML on Sure's origin.
    def stream_paperless_file(bytes, content_type, kind:, filename:)
      known_type = PaperlessLink::INLINE_CONTENT_TYPES.include?(content_type)
      inline = kind.to_s != "download" && known_type
      type = known_type ? content_type : "application/octet-stream"
      extension = Mime::Type.lookup(type).symbol if known_type
      basename = filename.to_s.parameterize.presence || "document"

      response.headers["Cache-Control"] = "private, max-age=3600" if kind.to_s == "thumb"
      send_data bytes, type: type, disposition: inline ? "inline" : "attachment",
                       filename: [ basename, extension ].compact.join(".")
    end
end
