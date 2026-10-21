class Settings::PaperlessController < ApplicationController
  layout "settings"

  before_action :set_connection
  before_action :require_manage_permission!, only: %i[update destroy verify]
  before_action :require_admin!, only: :mode

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t(".page_title"), nil ]
    ]
  end

  def update
    @connection ||= Current.family.paperless_connections.new(user: Current.family.paperless_shared_connection? ? nil : Current.user)
    @connection.assign_attributes(connection_params)

    if @connection.save
      if @connection.verify!
        redirect_to settings_paperless_path, notice: t(".success", version: @connection.server_version.presence || "?")
      else
        redirect_to settings_paperless_path, alert: t(".saved_but_unreachable", error: @connection.last_error)
      end
    else
      redirect_to settings_paperless_path, alert: @connection.errors.full_messages.to_sentence
    end
  end

  def verify
    if @connection&.verify!
      redirect_to settings_paperless_path, notice: t(".success", version: @connection.server_version.presence || "?")
    else
      redirect_to settings_paperless_path, alert: t(".failure", error: @connection&.last_error || t(".not_connected"))
    end
  end

  def destroy
    @connection&.destroy!
    redirect_to settings_paperless_path, notice: t(".success")
  end

  def mode
    if Current.family.update(paperless_connection_mode: params.require(:paperless_connection_mode))
      redirect_to settings_paperless_path, notice: t(".success")
    else
      redirect_to settings_paperless_path, alert: Current.family.errors.full_messages.to_sentence
    end
  end

  private
    def set_connection
      @connection = Current.family.paperless_connection_for(Current.user)
      @can_manage = Current.family.can_manage_paperless_connection?(Current.user)
    end

    def require_manage_permission!
      redirect_to settings_paperless_path, alert: t("settings.paperless.not_allowed") unless @can_manage
    end

    def require_admin!
      redirect_to settings_paperless_path, alert: t("settings.paperless.not_allowed") unless Current.user.admin?
    end

    # A blank token keeps the stored one, so the token never has to be shown again.
    def connection_params
      permitted = params.require(:paperless_connection).permit(:base_url, :api_token, :verify_ssl)
      permitted.delete(:api_token) if permitted[:api_token].blank? && @connection.persisted?
      permitted
    end
end
