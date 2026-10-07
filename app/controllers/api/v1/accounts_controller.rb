# frozen_string_literal: true

class Api::V1::AccountsController < Api::V1::BaseController
  include Pagy::Backend

  # Ensure proper scope authorization for read access
  before_action :ensure_read_scope
  # The forecast is a preview feature on the web and in the assistant too.
  before_action :require_preview_features_for_api, only: :forecast

  def index
    @per_page = safe_per_page_param

    @pagy, @accounts = pagy(
      accounts_scope.alphabetically,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue => e
    Rails.logger.error "AccountsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    unless valid_uuid?(params[:id])
      render json: {
        error: "not_found",
        message: "Account not found"
      }, status: :not_found
      return
    end

    @account = accounts_scope.find(params[:id])

    render :show
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "not_found",
      message: "Account not found"
    }, status: :not_found
  rescue => e
    Rails.logger.error "AccountsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  # What is left in the account after its expected payments (Account::Forecast).
  # `until` (YYYY-MM-DD) replaces the default window: up to the next declared
  # payday, else 30 days.
  def forecast
    unless valid_uuid?(params[:id])
      render json: { error: "not_found", message: "Account not found" }, status: :not_found
      return
    end

    @account = accounts_scope.find(params[:id])

    unless Account::Forecast.forecastable?(@account)
      render json: {
        error: "not_forecastable",
        message: "Forecasts are available for asset accounts whose money is available immediately"
      }, status: :unprocessable_entity
      return
    end

    until_date = parse_until_param
    return if performed?

    @forecast = Account::Forecast.for_account(@account, user: current_resource_owner, until_date: until_date)

    render :forecast
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found", message: "Account not found" }, status: :not_found
  rescue => e
    Rails.logger.error "AccountsController#forecast error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  private

    def parse_until_param
      return nil if params[:until].blank?

      today = Account.liquidity_today_for(@account.family)
      date = Date.iso8601(params[:until].to_s)

      if date < today || date > today + Account::Forecast::MAX_HORIZON_DAYS
        render json: {
          error: "invalid_until",
          message: "until must be between today and #{Account::Forecast::MAX_HORIZON_DAYS} days from today"
        }, status: :unprocessable_entity
        return nil
      end

      date
    rescue Date::Error
      render json: { error: "invalid_until", message: "until must be a date (YYYY-MM-DD)" }, status: :unprocessable_entity
      nil
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def accounts_scope
      scope = current_resource_owner.family.accounts
                                    .accessible_by(current_resource_owner)
                                    .includes(:accountable, account_providers: :provider)
      include_disabled_accounts? ? scope : scope.visible
    end

    def include_disabled_accounts?
      ActiveModel::Type::Boolean.new.cast(params[:include_disabled])
    end
end
