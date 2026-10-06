# The contract register, a segment of Bills. It shares the Bills gates (the
# preview flag and the family's recurring toggle) through
# RecurringFeatureGuardable. Every lookup is scoped to contracts the user can
# see: the owner plus explicit shares, with no admin override.
class ContractsController < ApplicationController
  include RecurringFeatureGuardable

  before_action :ensure_recurring_enabled
  before_action :set_contract, only: %i[show edit update destroy payments end_linked_bills]
  before_action :require_editable, only: %i[edit update payments end_linked_bills]
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
    @price_increases = Contract.recent_price_increases_for(@open_contracts, Current.user)
    # A related account grants nothing: its name shows only to users who can see it.
    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id).to_set
    @total_annual_cost, @unconvertible_count = total_annual_cost(@open_contracts)
    @annual_savings, @savings_count = Contract.annual_savings_for(contracts, Current.user, costs: @costs)
    @breadcrumbs = contracts_breadcrumb_prefix + [ [ t("contracts.index.title"), nil ] ]
  end

  # A printable overview of every open contract the user can see, with costs,
  # terms and contacts, for the household's folder. Numbers are always
  # masked: the printout is kept where others can read it.
  def overview
    @contracts = Current.family.contracts.accessible_by(Current.user).includes(:merchant, :owner, :contract_documents)
                        .alphabetically.to_a.select(&:open?)
                        .sort_by { |contract| [ Contract.kinds.keys.index(contract.kind), contract.name.downcase ] }
    @costs = Contract.annual_costs_for(@contracts, Current.user)
    # The accounts the visible active bills are paid from, by contract.
    @payment_accounts = RecurringTransaction.accessible_by(Current.user)
                                            .where(contract_id: @contracts.map(&:id), status: "active")
                                            .where(account_id: Current.user.accessible_accounts.select(:id))
                                            .includes(:account)
                                            .group_by(&:contract_id)
                                            .transform_values { |bills| bills.map { |bill| bill.account.name }.uniq }

    render layout: "print"
  end

  def show
    @visible_bills = @contract.visible_recurring_transactions_for(Current.user).includes(:merchant).order(:next_expected_date)
    @hidden_bills = @contract.hidden_recurring_transactions_for?(Current.user)
    @annual_cost, @unconvertible_count, @unconverted = @contract.annual_cost_for(Current.user)
    @price_changes = @contract.price_changes_for(Current.user).includes(:recurring_transaction).limit(10).to_a
    @next_payments = @contract.next_payments_for(Current.user)
    load_payment_history
    @schedule = @contract.notice_schedule
    @documents = @contract.contract_documents.with_attached_file.ordered
    @duplicates = @contract.editable_by?(Current.user) ? @contract.possible_duplicates.accessible_by(Current.user) : Contract.none
    @breadcrumbs = contracts_breadcrumb_prefix + [ [ t("contracts.index.title"), contracts_path ], [ @contract.name, nil ] ]
  end

  def new
    @contract = Current.family.contracts.new(kind: "other", owner: Current.user)
    prefill_from_bill(params[:recurring_transaction_id]) if params[:recurring_transaction_id].present?
    prefill_from_document(params[:pdf_import_id]) if params[:pdf_import_id].present?
    prefill_from_predecessor(params[:predecessor_id]) if params[:predecessor_id].present?
    render layout: dialog_layout
  end

  def create
    @contract = Current.family.contracts.new(owner: Current.user)
    @contract.assign_attributes(contract_params)
    assign_related_records

    if @contract.errors.none? && save_with_bills
      attach_source_document
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

  # Only the bill picker, for linking payments without the whole form. Bills
  # of the contract's merchant come first and are ticked while the contract
  # has no payments yet and they are not linked elsewhere.
  def payments
    @bills = linkable_bills.includes(:merchant).order(:name).to_a
    @selected_bill_ids = @contract.recurring_transaction_ids
    if @selected_bill_ids.empty? && @contract.merchant_id.present?
      @selected_bill_ids = @bills.select { |bill| bill.merchant_id == @contract.merchant_id && bill.contract_id.nil? }.map(&:id)
    end

    render layout: dialog_layout
  end

  def destroy
    @contract.destroy!
    redirect_to contracts_path, notice: t(".success")
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

    # The last year of payments by default; "show all" drops the window. A
    # contract's bills settle a few times a month at most, so even all of its
    # payments stay a short list.
    def load_payment_history
      @all_payments = params[:payments] == "all"
      since = @all_payments ? nil : Contract::PAYMENT_HISTORY_WINDOW.ago.to_date
      @payments = @contract.payments_for(Current.user, since: since).includes(entry: :account).to_a
      @older_payments = !@all_payments && @contract.payments_for(Current.user).where(recurring_allocations: { paid_on: ...since }).exists?
    end

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
        :name, :kind, :contract_number, :customer_number,
        :started_on, :minimum_term_months, :notice_period_value, :notice_period_unit, :notice_anchor,
        :renewal_period_months, :renewal_anchor_on,
        :portal_url, :service_phone, :service_email, :claims_phone, :notes, :email_reminders, :notice_not_required,
        document_links: [ :url, :label, :role ],
        details: Contract::DETAIL_FIELDS.values.flat_map(&:keys).uniq
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

      # A link to a record the editor cannot see is not in the select, so the
      # form submits it blank. Keep that link instead of clearing it.
      if attrs.key?(:account_id)
        hidden_account = @contract.account_id.present? && !Current.user.accessible_accounts.exists?(id: @contract.account_id)
        unless hidden_account && attrs[:account_id].blank?
          @contract.account = attrs[:account_id].presence && Current.user.accessible_accounts.find_by(id: attrs[:account_id])
          @contract.errors.add(:account, :invalid) if attrs[:account_id].present? && @contract.account.nil?
        end
      end

      # Any merchant the editor can pick: the family's own and the ones on
      # their transactions. The current one stays even when this editor could
      # not pick it.
      if attrs.key?(:merchant_id) && attrs[:merchant_id].to_s != @contract.merchant_id.to_s
        @contract.merchant = attrs[:merchant_id].presence && Current.family.available_merchants_for(Current.user).find_by(id: attrs[:merchant_id])
        @contract.errors.add(:merchant, :invalid) if attrs[:merchant_id].present? && @contract.merchant.nil?
      end

      # A new contract can name the one it replaces; that one, which the user
      # must be able to change, then points to it as its successor.
      if @contract.new_record? && attrs[:predecessor_id].present?
        @predecessor = predecessor_options.find_by(id: attrs[:predecessor_id])
        @contract.errors.add(:base, :invalid_predecessor) if @predecessor.nil?
      end

      if attrs.key?(:replaced_by_id)
        successor_scope = Current.family.contracts.accessible_by(Current.user).where.not(id: @contract.id)
        hidden_successor = @contract.replaced_by_id.present? && !successor_scope.exists?(id: @contract.replaced_by_id)
        unless hidden_successor && attrs[:replaced_by_id].blank?
          @contract.replaced_by = attrs[:replaced_by_id].presence && successor_scope.find_by(id: attrs[:replaced_by_id])
          @contract.errors.add(:replaced_by, :invalid) if attrs[:replaced_by_id].present? && @contract.replaced_by.nil?
        end
      end
    end

    # The bill picker lists the bills this user may change. Saving only touches
    # those: links to bills the user cannot see or change are left alone.
    def save_with_bills
      Contract.transaction do
        next false unless @contract.save

        if @predecessor && !@predecessor.update(replaced_by: @contract)
          @contract.errors.add(:base, :invalid_predecessor)
          raise ActiveRecord::Rollback
        end

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
    # account gate. A bill held by a contract the user cannot edit is left out.
    def linkable_bills
      Current.family.recurring_transactions
             .linkable_by(Current.user)
             .where.not(status: %w[suggested ended])
    end
    helper_method :linkable_bills

    # "Record as contract" from a bill: the bill's name and provider
    # seed the form, and the kind is guessed from how the bill is classified.
    def prefill_from_bill(recurring_transaction_id)
      bill = linkable_bills.find_by(id: recurring_transaction_id)
      return unless bill

      @contract.name = bill.display_name
      @contract.merchant = bill.merchant || Contract.merchant_named(Current.family, Current.user, bill.display_name)
      @suggested_merchant_name = bill.display_name if @contract.merchant.nil?
      @contract.kind = guess_kind(bill)
      @prefill_bill_ids = [ bill.id ]
    end

    # The contracts a new one may replace: those the user can change that are
    # not replaced yet, so no existing successor link is overwritten.
    def predecessor_options
      Current.family.contracts.editable_by(Current.user).where(replaced_by_id: nil)
    end
    helper_method :predecessor_options

    # "Add the new contract" after ending one: same kind, and the ended one is
    # preselected as the contract it replaces.
    def prefill_from_predecessor(predecessor_id)
      @predecessor = predecessor_options.find_by(id: predecessor_id)
      @contract.kind = @predecessor.kind if @predecessor
    end

    # "Create contract from this document" on a PDF import the processor
    # classified as a contract.
    def prefill_from_document(pdf_import_id)
      pdf_import = source_pdf_import(pdf_import_id)
      return unless pdf_import

      prefill = Contract::DocumentPrefill.new(pdf_import)
      prefill.apply_to(@contract)
      @contract.merchant = Contract.merchant_named(Current.family, Current.user, prefill.provider_name)
      @suggested_merchant_name = prefill.provider_name if @contract.merchant.nil?
      @source_pdf_import = pdf_import
      @document_premium = prefill.premium
    end

    def source_pdf_import(pdf_import_id)
      Current.family.imports.where(type: "PdfImport", document_type: "contract").find_by(id: pdf_import_id)
    end

    # The document a contract was created from becomes its first document. The
    # contract is already saved; a false result from document.save adds an alert
    # so the user can attach the file by hand. Exceptions are not rescued here.
    def attach_source_document
      pdf_import = source_pdf_import(params.dig(:contract, :pdf_import_id))
      return unless pdf_import&.pdf_file&.attached?

      document = @contract.contract_documents.new(role: "contract")
      document.file.attach(pdf_import.pdf_file.blob)
      flash[:alert] = t("contracts.create.document_not_attached") unless document.save
    end

    KIND_KEYWORDS = {
      "insurance" => /insur|versicher|allianz|axa|huk|ergo|generali|devk|signal iduna|debeka|zurich|gothaer/,
      "mobile" => /mobil|handy|telekom|vodafone|o2|telefonica|congstar|1&1|t-mobile|verizon|at&t/,
      "internet" => /internet|dsl|glasfaser|fiber|kabel|comcast|xfinity|spectrum/,
      "energy" => /strom|energie|energy|gas|electric|stadtwerke|eon|e\.on|vattenfall|enbw|rwe/,
      "streaming" => /netflix|spotify|disney|prime video|hulu|dazn|sky|apple tv|youtube|deezer|tidal/,
      "software" => /microsoft|adobe|google one|icloud|dropbox|1password|notion|github|openai|anthropic/,
      "fitness" => /fitness|gym|mcfit|urban sports|peloton|clever fit/,
      "rent" => /miete|rent|wohnung|landlord|vermiet/
    }.freeze

    # A deterministic guess from the bill's category and names; the user can
    # change it in the form.
    def guess_kind(bill)
      haystack = [ bill.category&.name, bill.merchant&.name, bill.name ].compact.join(" ").downcase
      KIND_KEYWORDS.each { |kind, pattern| return kind if haystack.match?(pattern) }
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
