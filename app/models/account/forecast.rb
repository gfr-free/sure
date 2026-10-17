# What is left in an account after the payments expected on it (decision E13,
# the "bills account" from the liquidity concept, section 7.11).
#
# Starts from today's balance and walks the open bill occurrences that touch
# the account: expenses paid from it, income paid into it, and recurring
# transfers out of it (`account_id`) or into it (`destination_account_id`).
# That last part is what makes a bills account work: "on the 1st, 800 arrive
# from the current account" keeps the account covered.
#
# The window runs up to the day before the next declared payday on this
# account, or 30 days when none is declared (decision F6). There is no
# statistical daily spend (F7): a pure bills account would otherwise always
# read as running dry.
#
# Only accounts whose money is reachable today take part (Account::Liquidity,
# `immediate`); credit cards stay out until there is limit logic. Every figure
# is in the account's own currency; occurrences in another currency are
# converted at today's rate and skipped (and counted) when no rate exists.
class Account::Forecast
  DEFAULT_HORIZON_DAYS = 30
  # A declared payday further out than this does not set the window: a
  # quarterly payment would otherwise stretch it over months.
  MAX_PAYDAY_DAYS = 45
  # Upper bound for an explicit `until` (API, assistant).
  MAX_HORIZON_DAYS = 366
  # Snoozed occurrences count on their snooze date, so the query reaches back
  # far enough to find one whose original due date has passed.
  SNOOZE_LOOKBACK_DAYS = 90

  # `restricted` marks a transfer whose other end the viewer cannot access:
  # it still moves this account's balance, but is shown without its name or a
  # link to the series.
  Event = Data.define(:date, :name, :kind, :amount, :balance_after, :occurrence, :series, :restricted)

  attr_reader :account, :starts_on, :ends_on, :horizon, :payday, :events,
              :starting_balance, :ending_balance, :low_balance, :low_on, :unconvertible_count

  class << self
    # The accounts a forecast is computed for: available today and holding
    # money (not a liability).
    def forecastable_scope(family, as_of: Account.liquidity_today_for(family))
      family.accounts.visible.immediate_assets_on(as_of)
    end

    def forecastable?(account, as_of: Account.liquidity_today_for(account.family))
      account.status.in?(Account::VISIBLE_STATUSES) && account.asset? && account.effective_liquidity(as_of) == "immediate"
    end

    # One forecast per forecastable account that has expected payments, built
    # from two queries for the whole family rather than per account. `user`
    # limits the accounts to the ones that user can access and anonymises
    # transfers from or to accounts they cannot; nil reads the family as a
    # whole (nightly insights).
    def for_family(family, user: nil, as_of: Account.liquidity_today_for(family))
      accounts = forecastable_scope(family, as_of: as_of)
      accounts = accounts.merge(Account.accessible_by(user)) if user
      accounts = accounts.to_a
      return [] if accounts.empty?

      loader = Loader.new(family, account_ids: accounts.map(&:id), user: user, as_of: as_of,
                          ends_on: as_of + [ MAX_PAYDAY_DAYS, DEFAULT_HORIZON_DAYS ].max)
      occurrences = loader.load

      accounts.filter_map do |account|
        mine = occurrences.select { |occurrence| touches?(occurrence, account) }
        next if mine.empty?

        new(account, as_of: as_of, occurrences: mine, visible_account_ids: loader.visible_account_ids)
      end
    end

    # The forecast for one account. `until_date` replaces the default window.
    def for_account(account, user: nil, as_of: Account.liquidity_today_for(account.family), until_date: nil)
      until_date = until_date&.clamp(as_of, as_of + MAX_HORIZON_DAYS)
      ends_on = until_date || as_of + [ MAX_PAYDAY_DAYS, DEFAULT_HORIZON_DAYS ].max
      loader = Loader.new(account.family, account_ids: [ account.id ], user: user, as_of: as_of, ends_on: ends_on)

      new(account, as_of: as_of, occurrences: loader.load, until_date: until_date,
                   visible_account_ids: loader.visible_account_ids)
    end

    def touches?(occurrence, account)
      series = occurrence.recurring_transaction
      series.account_id == account.id || series.destination_account_id == account.id
    end
  end

  # `visible_account_ids` (nil: all) are the accounts whose transfers may be
  # shown by name.
  def initialize(account, as_of:, occurrences:, until_date: nil, visible_account_ids: nil)
    @account = account
    @visible_account_ids = visible_account_ids
    @starts_on = as_of
    @unconvertible_count = 0

    if until_date
      @ends_on = until_date
      @horizon = :custom
    else
      @payday = next_payday(occurrences)
      @ends_on = @payday ? @payday - 1 : as_of + DEFAULT_HORIZON_DAYS
      @horizon = @payday ? :payday : :default
    end

    compute(occurrences)
  end

  # An expected payment takes the balance below zero, today included. An
  # account that is already overdrawn and stays flat is today's state, not a
  # forecast.
  def shortfall?
    low_balance.negative? && low_balance < starting_balance
  end

  # What has to arrive by the day before the low point to stay at zero.
  def shortfall_amount
    shortfall? ? -low_balance : Money.new(0, currency)
  end

  def top_up_by
    return nil unless shortfall?

    [ low_on - 1, starts_on ].max
  end

  # The largest payment leaving the account on the low day: what to name when
  # warning about it.
  def low_cause
    return nil unless shortfall?

    events.select { |event| event.date == low_on && event.amount.negative? }.min_by(&:amount)
  end

  def currency
    account.currency
  end

  def days
    (ends_on - starts_on).to_i
  end

  private
    def next_payday(occurrences)
      occurrences.select { |occurrence| payday?(occurrence) }
                 .map(&:effective_due_on)
                 .select { |date| date > starts_on && date <= starts_on + MAX_PAYDAY_DAYS }
                 .min
    end

    # Declared income only, like the paycheck planner: a detected inflow does
    # not define a payday.
    def payday?(occurrence)
      series = occurrence.recurring_transaction
      series.typed_income? && series.manual? && series.account_id == account.id && series.destination_account_id.nil?
    end

    def compute(occurrences)
      @starting_balance = account.balance_money
      @events = build_events(occurrences)

      balance = @starting_balance
      @low_balance = balance
      @low_on = starts_on

      @events = @events.group_by(&:date).sort.flat_map do |date, day_events|
        day_events.map do |event|
          balance += event.amount
          event.with(balance_after: balance)
        end.tap do
          if balance < @low_balance
            @low_balance = balance
            @low_on = date
          end
        end
      end

      @ending_balance = balance
    end

    def build_events(occurrences)
      occurrences.filter_map do |occurrence|
        date = occurrence.effective_due_on
        next if date > ends_on
        # Overdue rows are left out: an unmatched payment that already left the
        # account would otherwise be subtracted a second time.
        next if date < starts_on

        kind = kind_for(occurrence)
        next if kind.nil?

        amount = in_account_currency(occurrence.remaining_amount_money)
        next if amount.nil? || amount.zero?

        signed = kind.in?(%i[income transfer_in]) ? amount : -amount
        series = occurrence.recurring_transaction
        restricted = restricted?(series, kind)
        name = restricted ? I18n.t("account_forecast.restricted_transfer.#{kind}") : series.display_name

        Event.new(date: date, name: name, kind: kind, amount: signed, balance_after: nil,
                  occurrence: occurrence, series: series, restricted: restricted)
      end.sort_by { |event| [ event.date, event.amount.amount ] }
    end

    def kind_for(occurrence)
      series = occurrence.recurring_transaction

      if series.destination_account_id == account.id
        :transfer_in
      elsif series.account_id == account.id && series.destination_account_id.present?
        :transfer_out
      elsif series.account_id == account.id
        series.amount.negative? || series.typed_income? ? :income : :expense
      end
    end

    def restricted?(series, kind)
      return false if @visible_account_ids.nil?

      other_end = kind == :transfer_in ? series.account_id : series.destination_account_id
      other_end.present? && !@visible_account_ids.include?(other_end)
    end

    def in_account_currency(money)
      money.exchange_to(account.currency)
    rescue Money::ConversionError
      @unconvertible_count += 1
      nil
    end

    # Open occurrences of active series on the given accounts, with their
    # confirmed allocation sums preloaded so remaining amounts issue no
    # per-row SUM.
    #
    # With a user, only accounts that user can access are read. A series on
    # such an account counts even when its other end is hidden from them
    # (RecurringTransaction.accessible_by would drop it): a standing transfer
    # from a private account still funds a shared bills account. The forecast
    # shows such a transfer without its name (`visible_account_ids`).
    class Loader
      def initialize(family, account_ids:, user:, as_of:, ends_on:)
        @family = family
        @account_ids = account_ids
        @user = user
        @as_of = as_of
        @ends_on = ends_on
      end

      # Accounts in the family the user can access; nil without a user.
      def visible_account_ids
        return nil unless user

        @visible_account_ids ||= family.accounts.accessible_by(user).pluck(:id).to_set
      end

      def load
        ids = user ? account_ids.select { |id| visible_account_ids.include?(id) } : account_ids
        return [] if ids.empty?

        series = family.recurring_transactions.active
                       .where(account_id: ids).or(family.recurring_transactions.active.where(destination_account_id: ids))

        occurrences = family.recurring_occurrences
                            .open_status
                            .where(recurring_transaction_id: series.select(:id))
                            .where(due_on: (as_of - SNOOZE_LOOKBACK_DAYS)..ends_on)
                            .includes(:recurring_transaction)
                            .to_a

        sums = RecurringAllocation.confirmed
                                  .where(recurring_occurrence_id: occurrences.map(&:id))
                                  .group(:recurring_occurrence_id)
                                  .sum(:allocated_amount)
        occurrences.each { |occurrence| occurrence.cached_confirmed_allocated = sums.fetch(occurrence.id, 0) }
        occurrences
      end

      private
        attr_reader :family, :account_ids, :user, :as_of, :ends_on
    end
end
