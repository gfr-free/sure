class ContractDocumentIndexJob < ApplicationJob
  class SyncFailed < StandardError; end

  queue_as :medium_priority
  # The document (or the whole family) may be gone by the time this runs.
  discard_on ActiveJob::DeserializationError
  # A failed opt-in upload or opt-out removal is retried. An opted-out document
  # stays out of search results meanwhile; an opted-in one shows as pending.
  # An upload that keeps failing (a file the store cannot read, a long outage)
  # ends the opt-in, so the list does not say "waiting" forever and the owner
  # can try again.
  retry_on SyncFailed, wait: :polynomially_longer, attempts: 5 do |job, error|
    contract_document = job.arguments.first
    action = error.message
    if action == "upload"
      ContractDocument.where(id: contract_document.id, ai_searchable: true, family_document_id: nil)
                      .update_all(ai_searchable: false, updated_at: Time.current)
    end
    DebugLogEntry.capture(
      category: "background_jobs",
      level: "warn",
      message: "Contract document #{action} in the document store kept failing",
      source: job.class.name,
      family: contract_document.contract.family,
      metadata: { contract_document_id: contract_document.id, action: action, error_message: error.message }
    )
  end

  def perform(contract_document)
    action = contract_document.ai_searchable? ? "upload" : "removal"
    return if contract_document.sync_search_index!

    raise SyncFailed, action
  end
end
