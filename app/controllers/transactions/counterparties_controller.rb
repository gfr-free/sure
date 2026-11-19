# Assigns a transaction to a person from the transaction drawer, or releases it.
class Transactions::CounterpartiesController < ApplicationController
  before_action :require_preview_features!
  before_action :set_entry

  def update
    return unless require_account_permission!(@entry.account, redirect_path: transactions_path)

    assignment = Counterparty::Assignment.new(@entry)
    counterparty = find_counterparty

    if counterparty == :forbidden || !current_leg_writable?
      redirect_back_or_to transactions_path, alert: t("accounts.not_authorized")
      return
    end

    unless assignment.assignable? || counterparty.nil?
      redirect_back_or_to transactions_path, alert: t(".not_assignable")
      return
    end

    assignment.update!(counterparty, user: Current.user)
    redirect_back_or_to transactions_path, notice: counterparty ? t(".assigned", name: counterparty.name) : t(".released")
  rescue Counterparty::Assignment::NotAssignable, ActiveRecord::RecordInvalid
    redirect_back_or_to transactions_path, alert: t(".not_assignable")
  end

  private
    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    # nil releases; :forbidden when the user may not book onto that person.
    def find_counterparty
      id = params.dig(:transaction_counterparty, :counterparty_id).presence
      return nil unless id

      counterparty = Current.family.counterparties.visible_to(Current.user).find_by(id: id)
      return :forbidden unless counterparty&.assignable_by?(Current.user, currency: @entry.currency)

      counterparty
    end

    # Moving or releasing deletes the leg on the current person's account.
    def current_leg_writable?
      leg = Counterparty::Assignment.clearing_leg_for(@entry)
      leg.nil? || AccountPolicy.new(Current.user, leg.account).update?
    end
end
