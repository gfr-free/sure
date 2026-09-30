# Stock splits a family enters by hand from the holding drawer. They apply to
# this family's accounts only; splits reported by a price provider are shown
# alongside but cannot be removed here.
class HoldingSplitsController < ApplicationController
  before_action :set_holding
  before_action :require_split_permission!

  def create
    split = @holding.security.splits.new(split_params.merge(family: Current.family, source: "manual"))

    if split.save
      flash[:notice] = t(".success")
    else
      flash[:alert] = split.errors.full_messages.to_sentence
    end

    redirect_to account_path(@holding.account, tab: "holdings")
  end

  def destroy
    split = @holding.security.splits.where(family: Current.family).find(params[:id])
    split.destroy!

    redirect_to account_path(@holding.account, tab: "holdings"), notice: t(".success")
  end

  private
    def set_holding
      @holding = Current.family.holdings
                   .joins(:account)
                   .merge(Account.accessible_by(Current.user))
                   .find(params[:holding_id])
    end

    # A family's split changes all of the family's accounts holding the
    # security, not only this one.
    def require_split_permission!
      return if Security::Split.manageable_by?(user: Current.user, family: Current.family, security: @holding.security)

      redirect_back_or_to account_path(@holding.account, tab: "holdings"), alert: t("holding_splits.not_permitted")
    end

    def split_params
      params.require(:security_split).permit(:date, :ratio_from, :ratio_to)
    end
end
