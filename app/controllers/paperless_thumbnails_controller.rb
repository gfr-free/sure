# Thumbnails for search results, before a document is linked. Uses the current
# user's own connection, so it only ever shows what that token may see in Paperless.
class PaperlessThumbnailsController < ApplicationController
  include PaperlessFileStreaming

  def show
    connection = Current.family.paperless_connection_for(Current.user)
    return head(:not_found) if connection.nil?

    bytes, content_type = connection.client.file(params[:document_id], kind: :thumb)
    stream_paperless_file(bytes, content_type, kind: "thumb", filename: "thumb-#{params[:document_id]}")
  rescue Provider::Paperless::Error => e
    head(e.error_type == :not_found ? :not_found : :bad_gateway)
  end
end
