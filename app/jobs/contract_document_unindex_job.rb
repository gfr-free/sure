# A deleted contract document takes its copy in the assistant's document store
# with it.
class ContractDocumentUnindexJob < ApplicationJob
  queue_as :medium_priority
  # The document (or the whole family) may be gone by the time this runs.
  discard_on ActiveJob::DeserializationError

  def perform(family_document)
    family_document.family.remove_document(family_document)
  end
end
