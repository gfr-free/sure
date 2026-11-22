# frozen_string_literal: true

class ReceiptsController < ApplicationController
  before_action :require_preview_features!
  before_action :ensure_receipt_manager!
  before_action :set_receipt, except: %i[index create prefill]

  def index
    receipts = Current.family.receipts.uploaded_by(Current.user).with_attached_file.ordered
    @suggested_receipts = receipts.suggested.includes(linked_transaction: { entry: :account }).to_a
    @open_pagy, @open_receipts = pagy(receipts.open, limit: safe_per_page, page_param: :open_page)
    @bank_wait = bank_accounts_writable?
    @done_pagy, @done_receipts = pagy(receipts.done, limit: safe_per_page, page_param: :done_page)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("receipts.index.title"), receipts_path ] ]
  end

  def show
    @candidates = @receipt.match_candidates(Current.user)
    @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically
    # Bank accounts are offered once the wait for the bank's own booking is over.
    @bank_wait = @receipt.awaiting_bank? && bank_accounts_writable?
    @accounts = @accounts.where.not(id: Current.family.accounts.linked.select(:id)) if @bank_wait
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("receipts.index.title"), receipts_path ],
      [ @receipt.filename, nil ]
    ]
  end

  def file
    disposition = params[:disposition] == "attachment" ? "attachment" : "inline"
    redirect_to rails_blob_url(@receipt.file, disposition: disposition)
  end

  def create
    files = Array(params.dig(:receipt, :files)).select { |file| file.respond_to?(:read) }
    if files.empty?
      redirect_to receipts_path, alert: t(".no_files")
      return
    end

    created = 0
    duplicates = 0
    invalid = 0
    files.each do |file|
      Receipt.create_from_upload!(family: Current.family, user: Current.user, file: file)
      created += 1
    rescue Receipt::DuplicateUploadError
      duplicates += 1
    rescue Receipt::InvalidUploadError, ActiveRecord::RecordInvalid
      invalid += 1
    end

    redirect_to receipts_path, upload_flash(created:, duplicates:, invalid:)
  end

  def update
    @receipt.update_fields!(receipt_params)
    @receipt.auto_match!
    redirect_to receipt_path(@receipt), notice: t(".updated")
  rescue ActiveRecord::RecordInvalid
    redirect_to receipt_path(@receipt), alert: @receipt.errors.full_messages.to_sentence
  end

  def link
    transaction = @receipt.linkable_transactions(Current.user).find(params.require(:transaction_id))
    @receipt.link_to!(transaction, user: Current.user)
    redirect_to receipt_path(@receipt), notice: t(".linked")
  rescue ActiveRecord::RecordInvalid
    redirect_to receipt_path(@receipt), alert: @receipt.errors.full_messages.to_sentence
  end

  # Reads a receipt picked in the new-transaction form right away and reopens
  # the form filled with what was read. The receipt is linked once the
  # transaction is saved.
  def prefill
    file = params.dig(:receipt, :file)
    receipt = begin
      Receipt.create_from_upload!(family: Current.family, user: Current.user, file: file, extract_later: false)
    rescue Receipt::DuplicateUploadError => e
      e.receipt
    end

    unless receipt.status.in?(%i[open reading suggested])
      redirect_to new_transaction_path(receipt_error: "not_open", **new_transaction_context)
      return
    end

    receipt.extract! unless receipt.extraction_completed?
    redirect_to new_transaction_path(receipt_id: receipt.id, **new_transaction_context)
  rescue Receipt::InvalidUploadError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to new_transaction_path(receipt_error: "invalid", **new_transaction_context)
  end

  def confirm_match
    @receipt.confirm_match!(user: Current.user)
    redirect_back_or_to receipt_path(@receipt), notice: t(".confirmed")
  rescue ActiveRecord::RecordInvalid
    redirect_back_or_to receipt_path(@receipt), alert: @receipt.errors.full_messages.to_sentence
  end

  def reject_match
    @receipt.reject_match!
    redirect_back_or_to receipt_path(@receipt), notice: t(".rejected")
  rescue ActiveRecord::RecordInvalid
    redirect_back_or_to receipt_path(@receipt), alert: @receipt.errors.full_messages.to_sentence
  end

  def create_transaction
    account = Current.family.accounts.writable_by(Current.user).find(params.require(:account_id))
    attrs = new_transaction_params
    @receipt.create_transaction!(account: account, user: Current.user, **attrs)
    redirect_to receipt_path(@receipt), notice: t(".created")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to receipt_path(@receipt), alert: e.record.errors.full_messages.to_sentence
  end

  def dismiss
    @receipt.dismiss!
    redirect_to receipts_path, notice: t(".dismissed")
  end

  def reopen
    @receipt.reopen!
    @receipt.auto_match!
    redirect_to receipt_path(@receipt), notice: t(".reopened")
  end

  def destroy
    @receipt.destroy!
    redirect_to receipts_path, notice: t(".deleted")
  end

  private
    def ensure_receipt_manager!
      return if Receipt.manager?(Current.user)

      redirect_to root_path, alert: t("accounts.not_authorized")
    end

    # The account and type the new-transaction dialog was opened with.
    def new_transaction_context
      params.permit(:account_id, :nature).to_h.symbolize_keys.compact_blank
    end

    def bank_accounts_writable?
      Current.family.accounts.writable_by(Current.user).visible.linked.exists?
    end

    def set_receipt
      @receipt = Current.family.receipts.uploaded_by(Current.user).find(params[:id])
    end

    def receipt_params
      params.require(:receipt).permit(:merchant_name, :date, :amount, :currency)
    end

    def new_transaction_params
      permitted = params.require(:transaction).permit(:name, :date, :amount, :currency)
      {
        name: permitted[:name].to_s.squish.presence || @receipt.merchant_name || @receipt.filename,
        date: Date.iso8601(permitted[:date].to_s),
        amount: BigDecimal(permitted[:amount].to_s),
        currency: permitted[:currency].to_s.upcase.presence || @receipt.currency
      }
    rescue Date::Error, ArgumentError
      @receipt.errors.add(:base, :invalid_transaction)
      raise ActiveRecord::RecordInvalid, @receipt
    end

    def upload_flash(created:, duplicates:, invalid:)
      messages = []
      messages << t(".uploaded", count: created) if created.positive?
      messages << t(".duplicates", count: duplicates) if duplicates.positive?
      messages << t(".invalid", count: invalid) if invalid.positive?
      key = created.positive? ? :notice : :alert
      { key => messages.join(" ") }
    end
end
