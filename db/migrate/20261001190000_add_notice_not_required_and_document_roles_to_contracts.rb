# Contracts that never need notice (they end on their own or cannot be
# cancelled), and a role per contract document (policy, terms, invoice ...).
class AddNoticeNotRequiredAndDocumentRolesToContracts < ActiveRecord::Migration[8.1]
  ROLES = %w[contract terms amendment price_change invoice cancellation other].freeze

  def change
    add_column :contracts, :notice_not_required, :boolean, default: false, null: false

    add_column :contract_documents, :role, :string, default: "other", null: false
    add_check_constraint :contract_documents,
                         "role IN (#{ROLES.map { |role| "'#{role}'" }.join(', ')})",
                         name: "chk_contract_documents_role"
  end
end
