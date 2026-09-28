# The contract register, a segment of Bills. It shares the Bills gates (the
# preview flag and the family's recurring toggle) through
# RecurringFeatureGuardable. Every lookup is scoped to contracts the user can
# see: the owner plus explicit shares, with no admin override.
class ContractsController < ApplicationController
  include RecurringFeatureGuardable

  before_action :ensure_recurring_enabled
  before_action :set_contract, only: %i[show edit update destroy mark_ended end_linked_bills]
  before_action :require_editable, only: %i[edit update mark_ended end_linked_bills]
  before_action :require_manageable, only: %i[destroy]

  def index
    contracts = Current.family.contracts
                       .accessible_by(Current.user)
                       .includes(:merchant, :account, :contract_shares)
                       .alphabetically
                       .to_a

    @open_contracts, @ended_contracts = contracts.partition(&:open?)
    @groups = @open_contracts.group_by(&:kind).sort_by { |kind, _| Contract.kinds.keys.index(kind) }
    @costs = Contract.annual_costs_for(contracts, Current.user)
    @total_annual_cost, @unconvertible_count = total_annual_cost(@open_contracts)
    @breadcrumbs = contracts_breadcrumb_prefix + [ [ t("contracts.index.title"), nil ] ]
  end

  def show
    @visible_bills = @contract.visible_recurring_transactions_for(Current.user).includes(:merchant).order(:next_expected_date)
    @hidden_bills = @contract.hidden_recurring_transactions_for?(Current.user)
    @annual_cost, @unconvertible_count = @contract.annual_cost_for(Current.user)
    @schedule = @contract.notice_schedule
    @documents = @contract.contract_documents.with_attached_file.ordered
    @duplicates = @contract.editable_by?(Current.user) ? @contract.possible_duplicates.accessible_by(Current.user) : Contract.none
    @breadcrumbs = contracts_breadcrumb_prefix + [ [ t("contracts.index.title"), contracts_path ], [ @contract.name, nil ] ]
  end

  def new
    @contract = Current.family.contracts.new(kind: "other", owner: Current.user)
    prefill_from_bill(params[:recurring_transaction_id]) if params[:recurring_transaction_id].present?
    render layout: dialog_layout
  end

  def create
    @contract = Current.family.contracts.new(owner: Current.user)
    @contract.assign_attributes(contract_params)
    assign_related_records

    if @contract.errors.none? && save_with_bills
      flash[:notice] = t(".success")

      respond_to do |format|
        format.html { redirect_to contract_path(@contract) }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, contract_path(@contract)) }
      end
    else
      render :new, status: :unprocessable_entity, layout: dialog_layout
    end
  end

  def edit
    render layout: dialog_layout
  end

  def update
    @contract.assign_attributes(contract_params)
    assign_related_records

    if @contract.errors.none? && save_with_bills
      flash[:notice] = t(".success")

      respond_to do |format|
        format.html { redirect_to contract_path(@contract) }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, contract_path(@contract)) }
      end
    else
      render :edit, status: :unprocessable_entity, layout: dialog_layout
    end
  end

  def destroy
    @contract.destroy!
    redirect_to contracts_path, notice: t(".success")
  end

  def mark_ended
    @contract.mark_ended!(ended_on: Date.current)
    redirect_to contract_path(@contract), notice: t(".success")
  end

  # The contract has ended but its bills still expect payments. Ends the ones
  # this user may change, on the contract's end date.
  def end_linked_bills
    ends_on = @contract.ends_on || Date.current
    linkable_bills.where(contract_id: @contract.id, status: %w[active inactive paused]).find_each do |bill|
      bill.update!(end_mode: "on_date", end_on: ends_on)
    end

    redirect_back_or_to contract_path(@contract), notice: t(".success")
  end

  private

    def set_contract
      @contract = Current.family.contracts.accessible_by(Current.user).find(params[:id])
    end

    def require_editable
      raise ActiveRecord::RecordNotFound unless @contract.editable_by?(Current.user)
    end

    def require_manageable
      raise ActiveRecord::RecordNotFound unless @contract.manageable_by?(Current.user)
    end

    # Numbers are only mass-assigned for users who may see them in full; a
    # read-only share never reaches the form, and this keeps it that way.
    def contract_params
      params.require(:contract).permit(
        :name, :provider_name, :kind, :contract_number, :customer_number,
        :started_on, :minimum_term_months, :notice_period_value, :notice_period_unit, :notice_anchor,
        :renewal_period_months, :renewal_anchor_on, :ends_on,
        :portal_url, :service_phone, :service_email, :claims_phone, :notes, :email_reminders,
        document_links: [ :url, :label ]
      ).tap do |permitted|
        permitted[:document_links] = permitted[:document_links].to_h.values if permitted[:document_links].is_a?(ActionController::Parameters)
        %i[notice_period_unit notice_anchor].each { |key| permitted[key] = permitted[key].presence if permitted.key?(key) }
      end
    end

    # Account, merchant and successor are resolved rather than mass-assigned:
    # each must be something this user can reach, or a crafted id would point
    # the contract at a record they cannot see.
    def assign_related_records
      attrs = params.require(:contract)

      if attrs.key?(:account_id)
        @contract.account = attrs[:account_id].presence && Current.user.accessible_accounts.find_by(id: attrs[:account_id])
        @contract.errors.add(:account, :invalid) if attrs[:account_id].present? && @contract.account.nil?
      end

      if attrs.key?(:merchant_id)
        @contract.merchant = attrs[:merchant_id].presence && Current.family.merchants.find_by(id: attrs[:merchant_id])
        @contract.errors.add(:merchant, :invalid) if attrs[:merchant_id].present? && @contract.merchant.nil?
      end

      if attrs.key?(:replaced_by_id)
        successor_scope = Current.family.contracts.accessible_by(Current.user).where.not(id: @contract.id)
        @contract.replaced_by = attrs[:replaced_by_id].presence && successor_scope.find_by(id: attrs[:replaced_by_id])
        @contract.errors.add(:replaced_by, :invalid) if attrs[:replaced_by_id].present? && @contract.replaced_by.nil?
      end
    end

    # The bill picker lists the bills this user may change. Saving only touches
    # those: links to bills the user cannot see or change are left alone.
    def save_with_bills
      Contract.transaction do
        next false unless @contract.save

        if params[:contract].key?(:recurring_transaction_ids)
          selectable = linkable_bills
          selected_ids = Array(params[:contract][:recurring_transaction_ids]).compact_blank
          selectable.where(id: selected_ids).update_all(contract_id: @contract.id, updated_at: Time.current)
          selectable.where(contract_id: @contract.id).where.not(id: selected_ids).update_all(contract_id: nil, updated_at: Time.current)
        end

        true
      end
    end

    # Same write rule as RecurringTransactionsController#ensure_series_writable:
    # a bill on an account needs write access to it; an accountless bill has no
    # account gate.
    def linkable_bills
      writable = RecurringTransaction.where(account_id: nil)
                                     .or(RecurringTransaction.where(account_id: Account.writable_by(Current.user).select(:id)))

      Current.family.recurring_transactions
             .accessible_by(Current.user)
             .and(writable)
             .where.not(status: %w[suggested ended])
    end
    helper_method :linkable_bills

    # "Record as contract" from a bill: the bill's name, merchant and account
    # seed the form, and the kind is guessed from how the bill is classified.
    def prefill_from_bill(recurring_transaction_id)
      bill = linkable_bills.find_by(id: recurring_transaction_id)
      return unless bill

      @contract.name = bill.display_name
      @contract.merchant = bill.merchant if bill.merchant.is_a?(FamilyMerchant)
      @contract.provider_name = bill.merchant&.name if @contract.merchant.nil?
      @contract.provider_name ||= bill.display_name
      @contract.kind = guess_kind(bill)
      @prefill_bill_ids = [ bill.id ]
    end

    def guess_kind(bill)
      category_name = bill.category&.name.to_s.downcase
      return "insurance" if category_name.match?(/insur|versicher/)
      return "streaming" if bill.typed_subscription?

      "other"
    end

    def contracts_breadcrumb_prefix
      [ [ t("breadcrumbs.home"), root_path ], [ t("bills.index.title"), bills_path ] ]
    end

    def total_annual_cost(contracts)
      totals = contracts.filter_map { |contract| @costs.dig(contract.id, 0) }
      unconvertible = contracts.sum { |contract| @costs.dig(contract.id, 1).to_i }
      return [ nil, unconvertible ] if totals.empty?

      [ totals.sum(Money.new(0, Current.family.currency)), unconvertible ]
    end
end
