# Estimated tax on a person's returns for one year (liquidity concept,
# decisions E20/E21, STEUER.md S-1 to S-3). Sure estimates and shows; it never
# computes tax bindingly.
#
# Order per person and year (STEUER.md section 2): collect the booked returns,
# offset losses (loss pots), take off the allowance, apply the rate of each
# income type.
#
# Booked returns, from 1 January up to `as_of`, on the person's taxable
# accounts (Account::Taxation):
# - transactions labelled "Interest" or "Dividend";
# - realised gains and losses of sales (Trade#realized_gain_loss, average
#   cost) on investment accounts ("gains") and crypto accounts ("crypto").
#   Sales whose purchase price is unknown are left out and counted.
# Amounts are converted into the profile's currency on their date. On a
# joint account each person takes their share (E21 T1).
#
# Loss pots (LossPot, V-1) are kept per account, as banks do (T4). A loss
# from selling shares goes into the account's stocks pot when it has one,
# every other loss into the general pot. Gains take from the stocks pot first
# (share gains only), then from the general pot, which also offsets interest
# and dividends. A balance entered for a date already contains what happened
# up to that date, so only later returns use it or add to it; returns up to
# that date are only netted with each other, as the bank did. A balance from
# before last year is not used (LossPot#opening_for).
#
# Two kinds of account:
# - withheld: the bank books net and pays the tax. Its exemption order
#   (`tax_allowance_allocation`) keeps that much tax-free.
# - deferred: the bank books gross; the tax is due later with the return.
#   These accounts share the part of the allowance not given to a bank.
#
# `reserve` is the tax still due on the deferred accounts. It only exists when
# it can be worked out cleanly (S6): a profile with a rate and booked returns,
# never forecasts.
class Tax::Estimate
  INCOME_LABELS = { "Interest" => "interest", "Dividend" => "dividends" }.freeze
  GAIN_KINDS = %w[gains crypto].freeze

  Income = Data.define(:account_id, :date, :kind, :amount, :stock)
  Bank = Data.define(:label, :allocation, :income, :accounts) do
    def remaining
      [ allocation - income, 0 ].max
    end

    def used_up?
      allocation.positive? && income >= allocation
    end
  end
  # A loss pot as this person sees it this year, in the profile's currency:
  # the balance entered (and its date), losses added and amounts offset since,
  # and what is left. `covers_until` is the entered date when it falls in
  # this year: returns up to then are already in the balance. `pot` is nil
  # for the implicit pot of an account without entered balances.
  PotState = Data.define(:account, :kind, :pot, :entered, :entered_on, :covers_until, :outdated, :added, :used) do
    def remaining
      entered + added - used
    end
  end

  attr_reader :user, :year, :as_of, :profile

  # One estimate per person, computed once: callers that need several
  # accounts of the same people (forecast, budget) share them.
  def self.cache
    Hash.new { |hash, (user, year)| hash[[ user, year ]] = new(user, year: year) }
  end

  # The tax a further return of `amount` (in the account's currency) on
  # `account` would bear, summed over the people who share the account.
  # Nil when none of them has a rate for it.
  def self.tax_for_account(account, amount, kind:, year:, cache: self.cache)
    taxes = account.tax_shares.keys.filter_map { |person| cache[[ person, year ]].tax_for(account, amount, kind: kind) }
    taxes.sum if taxes.any?
  end

  # `viewer` limits the accounts to those that person can see, for figures
  # shown to someone else (the household budget).
  def initialize(user, year:, as_of: nil, viewer: nil)
    @user = user
    @year = year
    @viewer = viewer
    today = Account.liquidity_today_for(user&.family)
    @as_of = as_of || [ Date.new(year, 12, 31), today ].min
    @profile = TaxProfile.for(user, year)
    @unconvertible_count = 0
    @unconvertible_pots_count = 0
    @unknown_gains_count = 0
  end

  def profile?
    profile.present?
  end

  # Returns left out because no exchange rate was available.
  def unconvertible_count
    incomes
    @unconvertible_count
  end

  # Loss pot balances left empty because no exchange rate was available.
  def unconvertible_pots_count
    states_for_all_pots
    @unconvertible_pots_count
  end

  # Sales left out because their purchase price is unknown.
  def unknown_gains_count
    incomes
    @unknown_gains_count
  end

  def currency
    profile&.currency || user&.family&.currency
  end

  # The person's accounts whose returns are taxable: owned, or joint with
  # someone else.
  def accounts
    @accounts ||= if user.nil?
      []
    else
      scope = user.family.accounts.visible
                  .where(accountable_type: Account::Taxation::TAXABLE_TYPES)
                  .where("accounts.owner_id = :id OR accounts.tax_joint_user_id = :id", id: user.id)
      scope = scope.merge(Account.accessible_by(@viewer)) if @viewer && @viewer != user
      scope.distinct.includes(:accountable, :owner, :tax_joint_user, :account_shares, loss_pots: :snapshots).to_a
           .select { |account| account.returns_taxable? && share(account).positive? }
    end
  end

  def withheld?(account)
    withheld_ids.include?(account.id)
  end

  # The returns as booked (the person's share), before loss pots.
  def incomes
    @incomes ||= (load_incomes + load_gains).each_with_index.sort_by { |income, index| [ income.date, index ] }.map(&:first)
  end

  def income_total(kind: nil, account: nil)
    sum(incomes.select { |income| (kind.nil? || income.kind == kind) && (account.nil? || income.account_id == account.id) })
  end

  # What a kind brought in before losses: for gains only the sales with a
  # gain, since losses go into the pots. Shown above `offset_total`.
  def returns_total(kind)
    rows = incomes.select { |income| income.kind == kind }
    rows = rows.select { |income| income.amount.positive? } if kind.in?(GAIN_KINDS)
    sum(rows)
  end

  # Returns offset this year against losses: entered balances, this year's
  # losses and, up to an entered date, the losses the bank netted then.
  def offset_total
    offset_incomes
    pot_states.sum(0.to_d, &:used) + @window_used
  end

  # Loss pots with a balance or with losses this year.
  def pot_states
    states_for_all_pots
    @pot_states.values.select { |state| state.pot || state.added.positive? }
                .sort_by { |state| [ state.account.name, LossPot::KINDS.index(state.kind) ] }
  end

  # Exemption orders given to banks with a withholding account, the person's
  # share of them on joint accounts.
  def allocated_allowance
    @allocated_allowance ||= accounts.select { |account| withheld?(account) }.sum { |account| allocation_for(account) }
  end

  def over_allocated?
    profile&.annual_allowance.present? && allocated_allowance > profile.annual_allowance
  end

  # What the deferred accounts can still use: the allowance no bank holds.
  def deferred_allowance
    [ (profile&.allowance || 0) - allocated_allowance, 0 ].max
  end

  def deferred_tax
    @deferred_tax ||= tax_on(offset_incomes.reject { |income| withheld_ids.include?(income.account_id) }, deferred_allowance)
  end

  def withheld_tax
    @withheld_tax ||= accounts.select { |account| withheld?(account) }.sum do |account|
      tax_on(offset_incomes.select { |income| income.account_id == account.id }, allocation_for(account))
    end
  end

  # Kinds with booked returns but no rate in the profile: the estimate leaves
  # them out and says so.
  def missing_rates
    return [] unless profile?

    incomes.select { |income| income.amount.positive? }.map(&:kind).uniq.select { |kind| profile.rate_for(kind).nil? }
  end

  # The tax still due on returns booked gross this year, or nil when it
  # cannot be worked out cleanly (no profile, no rate).
  def reserve
    return nil unless profile&.rates?

    Money.new(deferred_tax.round(2), currency)
  end

  # Whether the reserve still counts: the person has not marked the year as
  # paid.
  def reserve_open?
    !user.tax_reserve_settled?(year)
  end

  # Exemption orders per bank (S-2): what each holds and what the returns
  # booked there, after loss pots, used of it.
  def banks
    @banks ||= accounts.select { |account| withheld?(account) && allocation_for(account).positive? }
                       .group_by(&:tax_institution_label)
                       .map do |label, bank_accounts|
      Bank.new(
        label: label,
        allocation: bank_accounts.sum { |account| allocation_for(account) },
        income: bank_accounts.sum { |account| [ taxable_total(account), 0 ].max },
        accounts: bank_accounts
      )
    end.sort_by(&:label)
  end

  # The tax a further return of `amount` (in the account's currency, of
  # `kind`) would bear for this person on `account`, after their share and
  # what is left of the loss pots and the allowance. Nil when the person has
  # no rate for it or no share in the account.
  def tax_for(account, amount, kind:)
    rate = profile&.rate_for(kind)
    portion = share(account)
    return nil if rate.nil? || !account.returns_taxable? || !portion.positive?

    money = Money.new(amount * portion, account.currency)
    converted = money.exchange_to(currency, date: as_of).amount
    converted = [ converted - pot_left_for(account, kind), 0 ].max if converted.positive?
    taxable = [ converted - remaining_allowance_for(account), 0 ].max
    Money.new(taxable * rate / 100, currency).exchange_to(account.currency, date: as_of).amount.round(2)
  rescue Money::ConversionError
    nil
  end

  private
    def share(account)
      account.tax_share_for(user)
    end

    def allocation_for(account)
      account.tax_allowance_allocation.to_d * share(account)
    end

    def withheld_ids
      @withheld_ids ||= accounts.select { |account| account.tax_withheld_at_source_in?(year) }.map(&:id).to_set
    end

    def taxable_total(account)
      sum(offset_incomes.select { |income| income.account_id == account.id })
    end

    def remaining_allowance_for(account)
      if withheld?(account)
        [ allocation_for(account) - taxable_total(account), 0 ].max
      else
        used = sum(offset_incomes.reject { |income| withheld_ids.include?(income.account_id) })
        [ deferred_allowance - used, 0 ].max
      end
    end

    # What the account's general pot still holds for a further return. The
    # stocks pot is left out: `kind` does not say whether a gain is from
    # shares.
    def pot_left_for(account, _kind)
      offset_incomes
      [ pot_state(account, "general").remaining, 0 ].max
    end

    # The returns after loss pots: losses fill the pots and leave the base,
    # gains and other returns take from them. Builds `@pot_states` as it goes.
    #
    # Up to an entered balance's date the bank already netted returns and
    # losses, and what was left over is in the balance. Those losses form a
    # separate pool (`@window`) that only returns of the same period use,
    # whatever their order, as the bank's refunds would.
    def offset_incomes
      @offset_incomes ||= begin
        @pot_states = {}
        @window = Hash.new(0.to_d)
        @window_used = 0.to_d
        incomes.each do |income|
          account = accounts_by_id.fetch(income.account_id)
          next unless loss?(income) && covered?(pot_state(account, loss_pot_kind(income, account)), income)

          @window[[ account.id, loss_pot_kind(income, account) ]] -= income.amount
        end
        incomes.map { |income| offset(income, accounts_by_id.fetch(income.account_id)) }
      end
    end

    def states_for_all_pots
      offset_incomes
      accounts.each { |account| account.loss_pots.each { |pot| pot_state(account, pot.kind) } }
    end

    def loss?(income)
      income.amount.negative? && income.kind.in?(GAIN_KINDS)
    end

    # Share losses go into the stocks pot where the account has one; every
    # other loss into the general pot.
    def loss_pot_kind(income, account)
      income.stock && account.loss_pot("stocks") ? "stocks" : "general"
    end

    def offset(income, account)
      return income if income.amount.zero?

      if income.amount.negative?
        # Reversed interest or dividends lower the base as they are.
        return income unless loss?(income)

        kind = loss_pot_kind(income, account)
        state = pot_state(account, kind)
        # A loss up to the entered date is in the window pool instead.
        @pot_states[[ account.id, kind ]] = state.with(added: state.added - income.amount) unless covered?(state, income)
        return income.with(amount: 0.to_d)
      end

      kinds = income.kind == "gains" && income.stock ? %w[stocks general] : %w[general]
      remaining = income.amount
      kinds.each do |kind|
        state = pot_state(account, kind)
        if covered?(state, income)
          used = [ @window[[ account.id, kind ]], remaining ].min
          @window[[ account.id, kind ]] -= used
          @window_used += used
        else
          used = [ [ state.remaining, 0 ].max, remaining ].min
          @pot_states[[ account.id, kind ]] = state.with(used: state.used + used) if used.positive?
        end
        remaining -= used
      end
      income.with(amount: remaining)
    end

    def covered?(state, income)
      state.covers_until.present? && income.date <= state.covers_until
    end

    def pot_state(account, kind)
      @pot_states[[ account.id, kind ]] ||= begin
        pot = account.loss_pot(kind)
        opening = pot&.opening_for(year, as_of: as_of)
        entered = opening ? convert_pot(opening.amount * share(account), account.currency, opening.date) : 0.to_d
        # A balance from an earlier year is the opening of this one.
        covers_until = opening.date if opening && opening.date.year == year
        PotState.new(account: account, kind: kind, pot: pot, entered: entered, entered_on: opening&.date,
                     covers_until: covers_until, outdated: pot&.outdated_for?(year, as_of: as_of) || false,
                     added: 0.to_d, used: 0.to_d)
      end
    end

    # Walks the returns in booking order, so the allowance is used up by the
    # earliest ones, and applies each kind's rate to what is left. Kinds
    # without a rate stay out. A reversal (negative return) lowers the base.
    def tax_on(rows, allowance)
      remaining = allowance
      tax = rows.sum(0.to_d) do |income|
        rate = profile&.rate_for(income.kind)
        next 0.to_d if rate.nil?

        free = income.amount.positive? ? [ remaining, income.amount ].min : 0
        remaining -= free
        (income.amount - free) * rate / 100
      end
      [ tax, 0 ].max
    end

    def sum(rows)
      rows.sum(0.to_d, &:amount)
    end

    def convert(amount, from, date)
      Money.new(amount, from).exchange_to(currency, date: date).amount
    rescue Money::ConversionError
      @unconvertible_count += 1
      nil
    end

    # A balance without an exchange rate counts as empty, which overstates
    # the tax rather than understating it, and is reported.
    def convert_pot(amount, from, date)
      Money.new(amount, from).exchange_to(currency, date: date).amount
    rescue Money::ConversionError
      @unconvertible_pots_count += 1
      0.to_d
    end

    def accounts_by_id
      @accounts_by_id ||= accounts.index_by(&:id)
    end

    def load_incomes
      return [] if accounts.empty? || currency.nil?

      Entry.where(account_id: accounts.map(&:id), entryable_type: "Transaction", excluded: false,
                  date: Date.new(year, 1, 1)..as_of)
           .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
           .where(transactions: { investment_activity_label: INCOME_LABELS.keys })
           .order(:date, :id)
           .pluck(:account_id, :date, :amount, :currency, "transactions.investment_activity_label")
           .filter_map do |account_id, date, amount, entry_currency, label|
        # Inflows are negative amounts in Sure.
        converted = convert(-amount * share(accounts_by_id.fetch(account_id)), entry_currency, date)
        next if converted.nil?

        Income.new(account_id: account_id, date: date, kind: INCOME_LABELS.fetch(label), amount: converted, stock: false)
      end
    end

    # Realised gains and losses of sales this year (S-3), at average cost.
    def load_gains
      gain_accounts = accounts.select(&:loss_pots_capable?)
      return [] if gain_accounts.empty? || currency.nil?

      trades = Trade.joins(:entry)
                    .where(entries: { account_id: gain_accounts.map(&:id), excluded: false, date: Date.new(year, 1, 1)..as_of })
                    .where("trades.qty < 0")
                    .where("trades.investment_activity_label IS NULL OR trades.investment_activity_label NOT IN (?)",
                           Trade::INTERNAL_MOVEMENT_LABELS)
                    .includes(:security, :entry)
                    .order("entries.date", "entries.id")
                    .to_a
      return [] if trades.empty?

      # Only the sold securities' positions up to the last sale: what
      # realized_gain_loss reads the average cost from.
      holdings = Holding.where(account_id: trades.map { |trade| trade.entry.account_id }.uniq,
                               security_id: trades.map(&:security_id).uniq,
                               date: ..trades.map { |trade| trade.entry.date }.max)
                        .group_by(&:account_id)
      trades.each do |trade|
        trade.entry.account = accounts_by_id.fetch(trade.entry.account_id)
        trade.instance_variable_set(:@preloaded_holdings, holdings[trade.entry.account_id] || [])
      end
      Trade.preload_exchange_rates(trades)

      trades.filter_map do |trade|
        account = trade.entry.account
        gain = trade.realized_gain_loss&.value
        if gain.nil?
          @unknown_gains_count += 1
          next
        end

        converted = convert(gain.amount * share(account), gain.currency.iso_code, trade.entry.date)
        next if converted.nil?

        Income.new(account_id: account.id, date: trade.entry.date, kind: account.accountable_type == "Crypto" ? "crypto" : "gains",
                   amount: converted, stock: trade.security&.asset_sub_class == "stock")
      end
    end
end
