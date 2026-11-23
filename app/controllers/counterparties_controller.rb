class CounterpartiesController < ApplicationController
  STATUSES = %w[active open archived].freeze

  before_action :require_preview_features!
  before_action :require_non_guest!, except: %i[index show]
  before_action :set_counterparty, only: %i[show edit update archive unarchive]
  before_action :require_manageable!, only: %i[edit update archive unarchive]

  def index
    @status = STATUSES.include?(params[:status]) ? params[:status] : "active"
    people = Current.family.counterparties.visible_to(Current.user).alphabetically.to_a
    @accounts_by_counterparty = accessible_clearing_accounts_by_counterparty(people)

    @counterparties = people.select do |person|
      accounts = @accounts_by_counterparty.fetch(person.id, [])
      case @status
      when "archived" then person.archived?
      when "open" then !person.archived? && accounts.any? { |account| account.balance.nonzero? }
      else !person.archived?
      end
    end

    @totals = totals_for(@accounts_by_counterparty.values.flatten)
  end

  def show
    @accounts = @counterparty.accounts.accessible_by(Current.user).alphabetically.to_a
  end

  def new
    @counterparty = Current.family.counterparties.new(default_currency: Current.family.currency)
  end

  def create
    @counterparty = Current.family.counterparties.new(counterparty_params.merge(created_by: Current.user))
    @counterparty.default_currency = Current.family.currency if @counterparty.default_currency.blank?

    saved = Counterparty.transaction do
      @counterparty.save && @counterparty.clearing_account_for!(@counterparty.default_currency, user: Current.user)
    rescue ActiveRecord::RecordInvalid => e
      @counterparty.errors.add(:base, e.record.errors.full_messages.to_sentence)
      raise ActiveRecord::Rollback
    end

    if saved
      redirect_to counterparty_path(@counterparty), notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @counterparty.update(counterparty_params.except(:default_currency))
      redirect_to counterparty_path(@counterparty), notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def archive
    if @counterparty.archive!
      redirect_to counterparties_path, notice: t(".success")
    else
      redirect_to counterparty_path(@counterparty), alert: t(".not_settled")
    end
  end

  def unarchive
    @counterparty.unarchive!
    redirect_to counterparty_path(@counterparty), notice: t(".success")
  end

  private
    def set_counterparty
      @counterparty = Current.family.counterparties.visible_to(Current.user).find(params[:id])
    end

    def require_manageable!
      return if @counterparty.manageable_by?(Current.user)

      redirect_to counterparty_path(@counterparty), alert: t("accounts.not_authorized")
    end

    def counterparty_params
      params.require(:counterparty).permit(:name, :note, :default_currency)
    end

    def accessible_clearing_accounts_by_counterparty(people)
      Current.user.accessible_accounts
        .where(accountable_type: "Clearing")
        .includes(:accountable)
        .where(accountable_id: Clearing.where(counterparty_id: people.map(&:id)).select(:id))
        .to_a
        .group_by { |account| account.clearing.counterparty_id }
    end

    # What others owe the user and what the user owes, in the family currency.
    # An account without a rate is left out rather than counted at 1.
    def totals_for(accounts)
      currency = Current.family.currency
      foreign = accounts.map(&:currency).uniq - [ currency ]
      rates = ExchangeRate.rates_for(foreign, to: currency, date: Date.current)

      owed_to_me = 0.to_d
      i_owe = 0.to_d
      accounts.each do |account|
        rate = account.currency == currency ? 1 : rates[account.currency]
        next unless rate

        amount = account.balance * rate
        amount.positive? ? owed_to_me += amount : i_owe -= amount
      end

      { owed_to_me: Money.new(owed_to_me, currency), i_owe: Money.new(i_owe, currency) }
    end
end
