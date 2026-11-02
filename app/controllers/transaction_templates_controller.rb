class TransactionTemplatesController < ApplicationController
  before_action :require_non_guest!
  before_action :set_template, only: %i[edit update destroy]
  before_action :set_form_options, only: %i[new create edit update]

  def index
    @templates = Current.family.transaction_templates
      .alphabetically
      .includes(:account, :category, :tags)
      .to_a
    @visible_account_ids = accessible_accounts.where(id: @templates.filter_map(&:account_id)).pluck(:id).to_set

    render layout: "settings"
  end

  def new
    @template = Current.family.transaction_templates.new(currency: Current.family.currency)
  end

  def create
    @template = Current.family.transaction_templates.new(template_params)

    if @template.save
      redirect_to transaction_templates_path, notice: t(".created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @template.update(template_params)
      redirect_to transaction_templates_path, notice: t(".updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @template.destroy!
    redirect_to transaction_templates_path, notice: t(".deleted")
  end

  private
    def set_template
      @template = Current.family.transaction_templates.find(params[:id])
    end

    def set_form_options
      @accounts = accessible_accounts.manual.active.alphabetically.to_a
      @categories = Current.family.categories.alphabetically_by_hierarchy.to_a
      @merchants = Current.family.merchants.alphabetically.to_a
      @tags = Current.family.tags.alphabetically.to_a
    end

    # The account, merchant, category and tags must be ones this person can
    # pick in the form. An account they cannot see stays as it is, because
    # the form does not show it.
    def template_params
      permitted = params.require(:transaction_template)
        .permit(:name, :nature, :amount, :currency, :account_id, :category_id, :merchant_id, :notes, tag_ids: [])

      permitted[:amount] = nil if permitted[:amount].blank?

      if permitted.key?(:account_id)
        if hidden_account?
          permitted.delete(:account_id)
        elsif permitted[:account_id].present?
          permitted[:account_id] = @accounts.find { |account| account.id == permitted[:account_id] }&.id
        else
          permitted[:account_id] = nil
        end
      end

      permitted[:category_id] = Current.family.categories.find_by(id: permitted[:category_id])&.id if permitted.key?(:category_id)
      permitted[:merchant_id] = Current.family.merchants.find_by(id: permitted[:merchant_id])&.id if permitted.key?(:merchant_id)
      permitted[:tag_ids] = Current.family.tags.where(id: permitted[:tag_ids].compact_blank).pluck(:id) if permitted.key?(:tag_ids)

      permitted
    end

    def hidden_account?
      @template&.persisted? && @template.account_id.present? && @accounts.none? { |account| account.id == @template.account_id }
    end
    helper_method :hidden_account?
end
