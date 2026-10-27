# frozen_string_literal: true

class Api::V1::HoldingsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :remap_security ]
  before_action :set_holding, only: [ :show ]
  before_action :set_writable_holding, only: [ :remap_security ]

  def index
    holdings_query = accessible_holdings

    holdings_query = apply_filters(holdings_query)
    holdings_query = holdings_query.includes(:account, :security).chronological

    @pagy, @holdings = pagy(
      holdings_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )
    @per_page = safe_per_page_param

    render :index
  rescue ArgumentError => e
    render_validation_error(e.message, [ e.message ])
  rescue => e
    log_and_render_error("index", e)
  end

  def show
    render :show
  rescue => e
    log_and_render_error("show", e)
  end

  # Moves the holding, the account's other holdings of the same security and
  # its trades to another security, as the holding drawer in the app does.
  def remap_security
    new_security = requested_security

    unless new_security
      render_validation_error("Security not found", [ "Provide the security_id of an existing security or a ticker" ])
      return
    end

    date = @holding.date
    currency = @holding.currency
    @holding.remap_security_and_materialize!(new_security)

    # The remap merges into an existing holding of the new security on the
    # same day, so this one may no longer exist.
    @holding = @holding.account.holdings.find_by!(security: new_security, date: date, currency: currency)
    render :show
  rescue => e
    log_and_render_error("remap_security", e)
  end

  private

    def set_holding
      @holding = accessible_holdings.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Holding not found" }, status: :not_found
    end

    # Holdings restricted to accounts the token owner can access (owned or shared),
    # not the whole family. Mirrors Api::V1::BalancesController and the web
    # HoldingsController, both of which scope through Account.accessible_by.
    def accessible_holdings
      Holding
        .joins(:account)
        .where(accounts: { status: %w[draft active], id: accessible_account_ids })
    end

    def set_writable_holding
      @holding = Holding
        .joins(:account)
        .where(accounts: { status: %w[draft active], id: current_resource_owner.family.accounts.writable_by(current_resource_owner).select(:id) })
        .find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Holding not found" }, status: :not_found
    end

    def remap_params
      params.fetch(:holding, {}).permit(:security_id, :ticker, :exchange_operating_mic)
    end

    # Cash securities belong to a single account and are never a valid target.
    def requested_security
      if remap_params[:security_id].present?
        Security.standard.find_by(id: remap_params[:security_id])
      else
        Security.resolve_typed_ticker(remap_params[:ticker], exchange_operating_mic: remap_params[:exchange_operating_mic])
      end
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts.accessible_by(current_resource_owner).select(:id)
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def apply_filters(query)
      if params[:account_id].present?
        query = query.where(account_id: params[:account_id])
      end
      if params[:account_ids].present?
        query = query.where(account_id: Array(params[:account_ids]))
      end
      if params[:date].present?
        query = query.where(date: parse_date!(params[:date], "date"))
      end
      if params[:start_date].present?
        query = query.where("holdings.date >= ?", parse_date!(params[:start_date], "start_date"))
      end
      if params[:end_date].present?
        query = query.where("holdings.date <= ?", parse_date!(params[:end_date], "end_date"))
      end
      if params[:security_id].present?
        query = query.where(security_id: params[:security_id])
      end
      query
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      case per_page
      when 1..100
        per_page
      else
        25
      end
    end

    def parse_date!(value, param_name)
      Date.parse(value)
    rescue Date::Error, ArgumentError, TypeError
      raise ArgumentError, "Invalid #{param_name} format"
    end

    def render_validation_error(message, errors)
      render json: {
        error: "validation_failed",
        message: message,
        errors: errors
      }, status: :unprocessable_entity
    end

    def log_and_render_error(action, exception)
      Rails.logger.error "HoldingsController##{action} error: #{exception.message}"
      Rails.logger.error exception.backtrace.join("\n")
      render json: {
        error: "internal_server_error",
        message: "An unexpected error occurred"
      }, status: :internal_server_error
    end
end
