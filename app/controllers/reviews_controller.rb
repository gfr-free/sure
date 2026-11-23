# The Review page: transactions that still need attention, counted per review
# kind under the usual transaction filters. Preview-gated.
class ReviewsController < ApplicationController
  before_action :require_preview_features!

  include FilterClearable
  include TransactionSearchParams

  def show
    @q = search_params
    @queue = Transaction::ReviewQueue.new(Current.family, user: Current.user, filters: @q)
    @kind = params[:kind].presence_in(Transaction::ReviewQueue::KINDS) || first_open_kind
    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id)

    @pagy, @transactions = pagy(
      @queue.transactions_for(@kind).reverse_chronological.includes(
        { entry: :account }, :category, { merchant: { logo_attachment: :blob } }, :tags,
        { transfer_as_outflow: { inflow_transaction: { entry: :account } } },
        { transfer_as_inflow: { inflow_transaction: { entry: :account }, outflow_transaction: [ :category, { entry: :account } ] } }
      ),
      limit: safe_per_page(50)
    )
    Transaction::ActivitySecurityPreloader.new(@transactions).preload
    @transfer_hint_transaction_ids = Current.family.transaction_ids_with_transfer_candidates(@transactions, user: Current.user)

    @split_parents = load_split_parents
    @split_parent_entry_ids = Entry.split_parent_ids_among(@transactions.map { |t| t.entry.id })
    @projected_recurring = []

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.review"), nil ] ]
  end

  def clear_filter
    redirect_to review_path(q: without_cleared_filter(search_params), kind: params[:kind].presence_in(Transaction::ReviewQueue::KINDS), per_page: params[:per_page])
  end

  private
    def load_split_parents
      return {} unless Current.user.show_split_grouped?

      parent_ids = @transactions.filter_map { |t| t.entry.parent_entry_id }.uniq
      return {} if parent_ids.empty?

      Entry.where(id: parent_ids).includes(:account, entryable: [ :category, :merchant ]).index_by(&:id)
    end

    # Opens on the first kind with work left, so the page never starts on an
    # empty list while another tile still has rows.
    def first_open_kind
      Transaction::ReviewQueue::KINDS.find { |kind| @queue.counts[kind].positive? } || Transaction::ReviewQueue::KINDS.first
    end
end
