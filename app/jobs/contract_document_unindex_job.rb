# A deleted contract document takes its copy in the assistant's document store
# with it. A failed removal is retried; until it succeeds the file stays out of
# search results because its contract document is gone.
class ContractDocumentUnindexJob < ApplicationJob
  class RemovalFailed < StandardError; end

  queue_as :medium_priority
  # The document (or the whole family) may be gone by the time this runs.
  discard_on ActiveJob::DeserializationError
  retry_on RemovalFailed, wait: :polynomially_longer, attempts: 5

  def perform(family_document)
    return if family_document.family.remove_document(family_document)
    # Without a store or a stored file there is nothing to retry.
    return if VectorStore.adapter.nil? || family_document.provider_file_id.blank?

    raise RemovalFailed, "Could not remove family document #{family_document.id} from the document store"
  end
end
