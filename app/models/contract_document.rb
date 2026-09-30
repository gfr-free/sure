# One file attached to a contract (policy, contract, cancellation
# confirmation). A row per file rather than has_many_attached on Contract, so
# each document can carry its own opt-in to the assistant's document search.
class ContractDocument < ApplicationRecord
  MAX_PER_CONTRACT = 10
  # Same file rules as transaction attachments: receipts and policies are the
  # same kind of paper.
  MAX_FILE_SIZE = Transaction::MAX_ATTACHMENT_SIZE
  ALLOWED_CONTENT_TYPES = Transaction::ALLOWED_CONTENT_TYPES

  belongs_to :contract
  belongs_to :family_document, optional: true

  has_one_attached :file, dependent: :purge_later

  validate :file_attached
  validate :file_constraints, if: -> { file.attached? }
  validate :within_contract_limit, on: :create

  scope :ai_searchable, -> { where(ai_searchable: true) }
  scope :ordered, -> { order(created_at: :desc) }

  delegate :filename, :byte_size, :content_type, to: :file

  after_destroy_commit :remove_from_search_index

  # The assistant's document store only takes some formats; a scanned photo
  # of a policy stays out of it.
  def indexable?
    file.attached? && VectorStore::Base::SUPPORTED_EXTENSIONS.include?(File.extname(file.filename.to_s).downcase)
  end

  # The owner opted this document in or out of the assistant's document
  # search. The vector-store upload runs in the background.
  def set_ai_searchable!(searchable)
    update!(ai_searchable: searchable && indexable?)
    ContractDocumentIndexJob.perform_later(self)
  end

  # Brings the vector store in line with the opt-in. The uploaded copy carries
  # the contract id, so search results can be filtered to contracts the asking
  # user may see.
  # Returns false when an opt-out could not be removed from the store yet.
  def sync_search_index!
    family = contract.family

    if ai_searchable? && family_document.nil? && indexable?
      document = family.upload_document(
        file_content: file.download,
        filename: file.filename.to_s,
        metadata: { "type" => "contract", "contract_id" => contract_id, "contract_document_id" => id }
      )
      return true unless document

      # The upload takes a while; the contract may have moved to another
      # family or been opted out meanwhile. Then the fresh copy goes again.
      # One conditional write, so an opt-out or move landing between a check
      # and the write cannot slip through.
      attached = ContractDocument.where(id: id, ai_searchable: true, family_document_id: nil)
                                 .where(contract_id: Contract.where(family_id: family.id).select(:id))
                                 .update_all(family_document_id: document.id, updated_at: Time.current)
      if attached == 1
        self.family_document_id = document.id
      else
        ContractDocumentUnindexJob.perform_later(document)
      end
      true
    elsif !ai_searchable? && family_document.present?
      return false unless family.remove_document(family_document)

      update_columns(family_document_id: nil, updated_at: Time.current)
      true
    else
      true
    end
  end

  private

    def remove_from_search_index
      ContractDocumentUnindexJob.perform_later(family_document) if family_document.present?
    end

    def file_attached
      errors.add(:file, :blank) unless file.attached?
    end

    def file_constraints
      errors.add(:file, :too_large, max_mb: MAX_FILE_SIZE / 1.megabyte) if file.byte_size > MAX_FILE_SIZE
      errors.add(:file, :invalid_format, file_format: file.content_type) unless ALLOWED_CONTENT_TYPES.include?(file.content_type)
    end

    def within_contract_limit
      return unless contract && contract.contract_documents.where.not(id: id).count >= MAX_PER_CONTRACT

      errors.add(:base, :too_many, max: MAX_PER_CONTRACT)
    end
end
