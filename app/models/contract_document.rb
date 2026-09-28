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

  private

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
