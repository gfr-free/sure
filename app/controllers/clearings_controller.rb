class ClearingsController < ApplicationController
  include AccountableResource

  before_action :require_preview_features!

  private
    # A clearing account's currency is fixed: each currency of a person has its
    # own account, and the transfer legs on it are in that currency.
    def account_params
      super.except(:currency, :accountable_type)
    end
end
