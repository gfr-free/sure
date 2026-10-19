# Shared lookup for the contract sub-resources (ending, sharing,
# documents). Same gates as ContractsController.
class Contracts::BaseController < ApplicationController
  include RecurringFeatureGuardable

  before_action :ensure_recurring_enabled
  before_action :set_contract

  private

    def set_contract
      @contract = Current.family.contracts.accessible_by(Current.user).find(params[:contract_id])
    end

    def require_editable
      raise ActiveRecord::RecordNotFound unless @contract.editable_by?(Current.user)
    end

    def require_manageable
      raise ActiveRecord::RecordNotFound unless @contract.manageable_by?(Current.user)
    end
end
