class TransactionPaperlessLinksController < ApplicationController
  SEARCH_WINDOW_DAYS = 30

  before_action :set_entry
  before_action :require_annotate_permission!
  before_action :set_connection, only: %i[new create]

  def new
    @text = params[:text].to_s.strip
    @created_from = parse_date(params[:created_from]) || @entry.date - SEARCH_WINDOW_DAYS
    @created_to = parse_date(params[:created_to]) || @entry.date + SEARCH_WINDOW_DAYS
    @linked_document_ids = @transaction.paperless_links.where(paperless_connection: @connection).pluck(:document_id)

    @documents = @connection.client.search_documents(text: @text, created_from: @created_from, created_to: @created_to)
  rescue Provider::Paperless::Error => e
    @connection.report_error(e, operation: "search")
    @documents = []
    @search_error = e.message
  end

  def create
    PaperlessLink.link!(linkable: @transaction, connection: @connection, document_id: params.require(:document_id), user: Current.user)
    redirect_back_or_to transactions_path, notice: t(".success")
  rescue ActiveRecord::RecordNotUnique
    redirect_back_or_to transactions_path, alert: t(".already_linked")
  rescue ActiveRecord::RecordInvalid => e
    alert = e.record.errors.of_kind?(:document_id, :taken) ? t(".already_linked") : t(".failed", error: e.record.errors.full_messages.to_sentence)
    redirect_back_or_to transactions_path, alert: alert
  rescue Provider::Paperless::Error => e
    @connection.report_error(e, operation: "link")
    redirect_back_or_to transactions_path, alert: t(".failed", error: e.message)
  end

  def destroy
    @transaction.paperless_links.find(params[:id]).destroy!
    redirect_back_or_to transactions_path, notice: t(".success")
  end

  private
    def set_entry
      @entry = Current.accessible_entries.where(entryable_type: "Transaction").find(params[:transaction_id])
      @transaction = @entry.transaction
    end

    def require_annotate_permission!
      return if @entry.account.permission_for(Current.user).in?(%i[owner full_control read_write])

      redirect_back_or_to transactions_path, alert: t("accounts.not_authorized")
    end

    def set_connection
      @connection = Current.family.paperless_connection_for(Current.user)
      redirect_to settings_paperless_path, alert: t("transaction_paperless_links.not_connected") if @connection.nil?
    end

    def parse_date(value)
      Date.iso8601(value) if value.present?
    rescue Date::Error
      nil
    end
end
