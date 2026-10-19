class PaperlessLinksController < ApplicationController
  include PaperlessFileStreaming

  def file
    link = Current.family.paperless_links.find(params[:id])
    raise ActiveRecord::RecordNotFound unless link.visible_to?(Current.user)

    bytes, content_type = link.file(params[:kind])
    stream_paperless_file(bytes, content_type, kind: params[:kind], filename: link.title.presence || "document-#{link.document_id}")
  rescue Provider::Paperless::Error => e
    link&.paperless_connection&.report_error(e, operation: "file")
    head(e.error_type == :not_found ? :not_found : :bad_gateway)
  end
end
