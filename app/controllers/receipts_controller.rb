# frozen_string_literal: true

class ReceiptsController < ApplicationController
  before_action :require_preview_features!
  before_action :ensure_receipt_manager!
  before_action :set_receipt, except: %i[index create]

  def index
    receipts = Current.family.receipts.uploaded_by(Current.user).with_attached_file.ordered
    @open_pagy, @open_receipts = pagy(receipts.open, limit: safe_per_page, page_param: :open_page)
    @done_pagy, @done_receipts = pagy(receipts.done, limit: safe_per_page, page_param: :done_page)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("receipts.index.title"), receipts_path ] ]
  end

  def show
    @candidates = @receipt.match_candidates(Current.user)
    @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically
    @linked_entry = visible_linked_entry
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
    failed = 0
    files.each do |file|
      Receipt.create_from_upload!(family: Current.family, user: Current.user, file: file)
      created += 1
    rescue Receipt::DuplicateUploadError
      duplicates += 1
    rescue Receipt::InvalidUploadError, ActiveRecord::RecordInvalid
      invalid += 1
    rescue StandardError => e
      # A storage error on one file must not hide the files already stored.
      failed += 1
      DebugLogEntry.capture(category: "receipts", level: "error", message: "Receipt upload failed: #{e.class}",
                            source: "receipt_upload", family: Current.family, user_id: Current.user.id)
    end

    redirect_to receipts_path, upload_flash(created:, duplicates:, invalid:, failed:)
  end

  def update
    @receipt.update_fields!(receipt_params, params.fetch(:rendered, {}).permit(*Receipt::FIELDS))
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

    def set_receipt
      @receipt = Current.family.receipts.uploaded_by(Current.user).find(params[:id])
    end

    # A linked transaction stays on the receipt after its account stops being
    # shared with the uploader; its details are then no longer shown.
    def visible_linked_entry
      entry = @receipt.linked_transaction&.entry
      entry if entry && Current.family.accounts.accessible_by(Current.user).where(id: entry.account_id).exists?
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

    def upload_flash(created:, duplicates:, invalid:, failed:)
      messages = []
      messages << t(".uploaded", count: created) if created.positive?
      messages << t(".duplicates", count: duplicates) if duplicates.positive?
      messages << t(".invalid", count: invalid) if invalid.positive?
      messages << t(".failed", count: failed) if failed.positive?
      key = created.positive? ? :notice : :alert
      { key => messages.join(" ") }
    end
end
