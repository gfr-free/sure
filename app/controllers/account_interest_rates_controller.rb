# Removes one entry from an account's interest rate history (Account::Interest),
# e.g. a planned change that will not happen. Adding and changing rates goes
# through the account form.
class AccountInterestRatesController < ApplicationController
  before_action :set_account

  def destroy
    @account.interest_rates.find(params[:id]).destroy!

    redirect_to account_path(@account, tab: "interest"), notice: t(".success")
  end

  private
    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
      require_account_permission!(@account)
    end
end
