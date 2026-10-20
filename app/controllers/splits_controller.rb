class SplitsController < ApplicationController
  before_action :set_entry
  before_action :require_split_write_permission!, only: %i[create update destroy]

  def new
    @categories = grouped_categories
  end

  def create
    unless @entry.transaction.splittable?
      redirect_back_or_to transactions_path, alert: t("splits.create.not_splittable")
      return
    end

    raw_splits = split_params[:splits]
    raw_splits = raw_splits.values if raw_splits.respond_to?(:values)

    splits = raw_splits.map do |s|
      { name: s[:name], amount: s[:amount].to_d * -1, category_id: s[:category_id].presence, excluded: s[:excluded] }
    end

    @entry.split!(splits)
    @entry.sync_account_later

    redirect_back_or_to transactions_path, notice: t("splits.create.success")
  rescue ActiveRecord::RecordInvalid => e
    redirect_back_or_to transactions_path, alert: e.message
  end

  def edit
    resolve_to_parent!

    unless @entry.split_parent?
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end

    @categories = grouped_categories
    @children = @entry.child_entries.includes(:entryable)
  end

  def update
    resolve_to_parent!

    unless @entry.split_parent?
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end

    raw_splits = split_params[:splits]
    raw_splits = raw_splits.values if raw_splits.respond_to?(:values)

    merchant_ids = available_merchant_ids(raw_splits.map { |s| s[:merchant_id] })

    splits = raw_splits.map do |s|
      split = { name: s[:name], amount: s[:amount].to_d * -1, category_id: s[:category_id].presence, excluded: s[:excluded] }
      split[:merchant_id] = s[:merchant_id].presence if s.key?(:merchant_id) && (s[:merchant_id].blank? || merchant_ids.include?(s[:merchant_id]))
      split
    end

    Entry.transaction do
      @entry.unsplit!
      @entry.split!(splits)
    end

    @entry.sync_account_later

    redirect_to transactions_path, notice: t("splits.update.success")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to transactions_path, alert: e.message
  end

  def destroy
    resolve_to_parent!

    unless @entry.split_parent?
      redirect_to transactions_path, alert: t("splits.edit.not_split")
      return
    end

    @entry.unsplit!
    @entry.sync_account_later

    redirect_to transactions_path, notice: t("splits.destroy.success")
  end

  private

    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    def require_split_write_permission!
      require_account_permission!(@entry.account, redirect_path: transactions_path)
    end

    def resolve_to_parent!
      @entry = @entry.parent_entry if @entry.split_child?
    end

    def split_params
      params.require(:split).permit(splits: [ :name, :amount, :category_id, :merchant_id, :excluded ])
    end

    # The edit form carries a split's own merchant (or its explicit "none") so
    # re-creating the splits keeps it. Accept only merchants already on one of
    # the splits or belonging to the family.
    def available_merchant_ids(merchant_ids)
      merchant_ids = merchant_ids.compact_blank
      return Set.new if merchant_ids.empty?

      split_merchant_ids = Transaction.where(id: @entry.child_entries.select(:entryable_id), merchant_id: merchant_ids).pluck(:merchant_id)
      family_merchant_ids = Current.family.merchants.where(id: merchant_ids).pluck(:id)
      (split_merchant_ids + family_merchant_ids).to_set
    end

    def grouped_categories
      Current.family.categories.alphabetically_by_hierarchy
    end
end
