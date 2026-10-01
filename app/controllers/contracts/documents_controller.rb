# Uploading and removing contract documents, their role (policy, terms,
# invoice ...), and the per-document opt-in to the assistant's document search.
class Contracts::DocumentsController < Contracts::BaseController
  before_action :require_editable, except: :show
  before_action :set_document, only: %i[show update destroy]

  # Access-checked: the blob URL is only handed out to someone who may see
  # the contract.
  def show
    disposition = params[:disposition] == "attachment" ? "attachment" : "inline"
    redirect_to rails_blob_url(@document.file, disposition: disposition)
  end

  def create
    files = Array(params.dig(:contract_document, :files)).compact_blank
    remaining = ContractDocument::MAX_PER_CONTRACT - @contract.contract_documents.count

    if files.empty?
      return redirect_to contract_path(@contract), alert: t(".no_file")
    elsif files.size > remaining
      return redirect_to contract_path(@contract), alert: t(".too_many", max: ContractDocument::MAX_PER_CONTRACT)
    end

    role = params.dig(:contract_document, :role).to_s.presence_in(ContractDocument::ROLES) || "other"
    errors = []
    ContractDocument.transaction do
      files.each do |file|
        document = @contract.contract_documents.new(role: role)
        document.file.attach(file)
        errors.concat(document.errors.full_messages) unless document.save
      end
      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      redirect_to contract_path(@contract), alert: errors.uniq.to_sentence
    else
      redirect_to contract_path(@contract), notice: t(".success", count: files.size)
    end
  end

  def update
    if (role = params.dig(:contract_document, :role)).present?
      return update_role(role)
    end

    searchable = ActiveModel::Type::Boolean.new.cast(params.dig(:contract_document, :ai_searchable))

    if searchable && !Current.user.ai_enabled?
      return redirect_to contract_path(@contract), alert: t(".ai_disabled")
    end

    @document.set_ai_searchable!(searchable)
    redirect_to contract_path(@contract), notice: t(searchable ? ".searchable" : ".not_searchable")
  end

  def destroy
    @document.destroy!
    redirect_to contract_path(@contract), notice: t(".success")
  end

  private

    def update_role(role)
      if @document.update(role: role.to_s.presence_in(ContractDocument::ROLES))
        redirect_to contract_path(@contract), notice: t(".role_updated")
      else
        redirect_to contract_path(@contract), alert: @document.errors.full_messages.to_sentence
      end
    end

    def set_document
      @document = @contract.contract_documents.find(params[:id])
    end
end
