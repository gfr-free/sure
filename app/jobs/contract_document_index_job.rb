class ContractDocumentIndexJob < ApplicationJob
  class RemovalFailed < StandardError; end

  queue_as :medium_priority
  # The document (or the whole family) may be gone by the time this runs.
  discard_on ActiveJob::DeserializationError
  # An opted-out document stays out of search results while its removal from
  # the store is retried.
  retry_on RemovalFailed, wait: :polynomially_longer, attempts: 5 do |job, error|
    contract_document = job.arguments.first
    DebugLogEntry.capture(
      category: "background_jobs",
      level: "warn",
      message: "Opted-out contract document could not be removed from the document store",
      source: job.class.name,
      family: contract_document.contract.family,
      metadata: { contract_document_id: contract_document.id, error_message: error.message }
    )
  end

  def perform(contract_document)
    return if contract_document.sync_search_index!

    raise RemovalFailed, "Could not remove contract document #{contract_document.id} from the document store"
  end
end
