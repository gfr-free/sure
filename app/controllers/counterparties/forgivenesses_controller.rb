class Counterparties::ForgivenessesController < ApplicationController
  before_action :require_preview_features!
  before_action :set_counterparty_and_account

  def new
    @categories = Current.family.categories.alphabetically_by_hierarchy
  end

  def create
    category = Current.family.categories.find_by(id: params.dig(:forgiveness, :category_id).presence)

    if @counterparty.forgive!(account: @account, category: category)
      redirect_to counterparty_path(@counterparty), notice: t(".success")
    else
      redirect_to counterparty_path(@counterparty), alert: t(".nothing_to_forgive")
    end
  end

  private
    def set_counterparty_and_account
      @counterparty = Current.family.counterparties.visible_to(Current.user).find(params[:counterparty_id])
      @account = @counterparty.accounts.accessible_by(Current.user).find(params[:account_id] || params.dig(:forgiveness, :account_id))
      require_account_permission!(@account, redirect_path: counterparty_path(@counterparty))
    end
end
