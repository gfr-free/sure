class ContractDocumentIndexJob < ApplicationJob
  queue_as :medium_priority
  # The document (or the whole family) may be gone by the time this runs.
  discard_on ActiveJob::DeserializationError

  def perform(contract_document)
    contract_document.sync_search_index!
  end
end
