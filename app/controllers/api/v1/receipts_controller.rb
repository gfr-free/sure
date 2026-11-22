# frozen_string_literal: true

# The receipt inbox for API clients such as the mobile app. Like the web inbox,
# it sits behind preview features, is open to admins and members, and only ever
# shows the caller's own uploads.
class Api::V1::ReceiptsController < Api::V1::BaseController
  include Pagy::Backend
  include ActiveStorage::Streaming

  wrap_parameters false

  READ_ACTIONS = %i[index show file candidates].freeze
  STATUSES = %w[open linked dismissed].freeze

  before_action :ensure_read_scope, only: READ_ACTIONS
  before_action :ensure_write_scope, except: READ_ACTIONS
  before_action :ensure_receipt_manager
  before_action :require_preview_features_for_api
  before_action :set_receipt, except: %i[index create]

  helper_method :accessible_account_ids

  def index
    receipts = own_receipts.includes(linked_transaction: { entry: :account }).ordered
    receipts = apply_filters(receipts)

    @per_page = safe_per_page_param
    @pagy, @receipts = pagy(receipts, page: safe_page_param, limit: @per_page)

    render :index
  end

  def show
    render :show
  end

  def file
    # API keys carry no session, which the blob routes require, so the file is sent here.
    send_blob_stream @receipt.file.blob, disposition: params[:disposition] == "attachment" ? :attachment : :inline
  end

  def candidates
    @candidates = @receipt.match_candidates(current_resource_owner)
    render :candidates
  end

  def create
    file = params[:file]
    unless file.respond_to?(:read) && file.respond_to?(:original_filename)
      render_validation_error("file is required (multipart/form-data)")
      return
    end

    @receipt = Receipt.create_from_upload!(family: family, user: current_resource_owner, file: file, source: "api")
    render :show, status: :created
  rescue Receipt::DuplicateUploadError => e
    # Duplicates are only looked up among the caller's own receipts, so the
    # existing one is always theirs to see.
    @receipt = e.receipt
    @duplicate = true
    render :show, status: :ok
  rescue Receipt::InvalidUploadError
    render_validation_error(
      "file must be a JPEG, PNG, GIF, WebP or PDF whose contents match its name, " \
      "at most #{Receipt::MAX_FILE_SIZE / 1.megabyte} MB"
    )
  rescue ActiveRecord::RecordInvalid => e
    render_record_invalid(e.record)
  end

  def update
    attrs = field_params
    return if performed?

    @receipt.update_fields!(attrs)
    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_record_invalid(e.record)
  end

  def link
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params.require(:transaction_id))

    transaction = @receipt.linkable_transactions(current_resource_owner).find(params[:transaction_id])
    @receipt.link_to!(transaction, user: current_resource_owner)
    render :show
  rescue ActiveRecord::RecordInvalid => e
    render_record_invalid(e.record)
  end

  def create_transaction
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params.require(:account_id))

    account = family.accounts.writable_by(current_resource_owner).find(params[:account_id])
    attrs = new_transaction_params
    return if performed?

    @receipt.create_transaction!(account: account, user: current_resource_owner, **attrs)
    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_record_invalid(e.record)
  end

  def dismiss
    @receipt.dismiss!
    render :show
  end

  def reopen
    @receipt.reopen!
    render :show
  end

  def destroy
    @receipt.destroy!
    head :no_content
  end

  private

    def family
      current_resource_owner.family
    end

    def own_receipts
      family.receipts.uploaded_by(current_resource_owner)
    end

    def set_receipt
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @receipt = own_receipts.includes(linked_transaction: { entry: :account }).find(params[:id])
    end

    # A linked transaction is only described when the caller can still see its
    # account; access may have been withdrawn since linking.
    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.accessible_accounts.pluck(:id).to_set
    end

    def apply_filters(scope)
      if params[:status].present?
        status = params[:status].to_s
        raise InvalidFilterError, "status must be one of: #{STATUSES.join(", ")}" unless STATUSES.include?(status)

        scope = case status
        when "open" then scope.open
        when "linked" then scope.where.not(transaction_id: nil)
        when "dismissed" then scope.where(transaction_id: nil).where.not(dismissed_at: nil)
        end
      end

      if params[:extraction_status].present?
        unless Receipt.extraction_statuses.key?(params[:extraction_status].to_s)
          raise InvalidFilterError, "extraction_status must be one of: #{Receipt.extraction_statuses.keys.join(", ")}"
        end

        scope = scope.where(extraction_status: params[:extraction_status].to_s)
      end

      # The column only holds lowercase hex.
      scope = scope.where(content_sha256: params[:content_sha256].to_s.strip.downcase) if params[:content_sha256].present?
      scope
    end

    # Unlike the web form, a value that cannot be read is an error rather than
    # a silent blank. An explicit null clears the field.
    def field_params
      permitted = params.permit(*Receipt::FIELDS).to_h
      return render_validation_error("Provide at least one of: #{Receipt::FIELDS.join(", ")}") if permitted.empty?

      unless permitted["date"].nil?
        permitted["date"] = parse_date(permitted["date"])
        return render_validation_error("date must be an ISO 8601 date (YYYY-MM-DD)") if permitted["date"].nil?
      end

      unless permitted["amount"].nil?
        permitted["amount"] = parse_decimal(permitted["amount"])
        return render_validation_error("amount must be a number") if permitted["amount"].nil?
      end

      permitted
    end

    # Missing values fall back to what was read from the receipt, as in the web form.
    def new_transaction_params
      date = params[:date].present? ? parse_date(params[:date]) : @receipt.date
      amount = params[:amount].present? ? parse_decimal(params[:amount]) : @receipt.amount

      if date.nil?
        render_validation_error("date must be an ISO 8601 date (YYYY-MM-DD); the receipt has none to fall back to")
        return
      end

      if amount.nil? || !amount.positive?
        render_validation_error("amount must be a positive number; the receipt has none to fall back to")
        return
      end

      {
        name: params[:name].to_s.squish.presence || @receipt.merchant_name || @receipt.filename,
        date: date,
        amount: amount,
        currency: params[:currency].to_s.strip.upcase.presence || @receipt.currency
      }
    end

    def render_record_invalid(record)
      render json: {
        error: "validation_failed",
        message: "Receipt could not be saved",
        errors: record.errors.full_messages
      }, status: :unprocessable_entity
    end

    def ensure_receipt_manager
      return if Receipt.manager?(current_resource_owner)

      render_json({ error: "forbidden", message: "Receipts require an admin or member role" }, status: :forbidden)
    end

    def require_preview_features_for_api
      return if current_resource_owner.preview_features_enabled?

      render_json(
        { error: "feature_disabled", message: "Preview features are not enabled for this user" },
        status: :forbidden
      )
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end
end
