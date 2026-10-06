# Estimated tax on a person's returns for one year (liquidity concept,
# decision E20, STEUER.md S-1/S-2). Sure estimates and shows; it never
# computes tax bindingly.
#
# Order per person and year (STEUER.md section 2): collect the booked returns,
# take off the allowance, apply the rate of each income type. Loss pots come
# in a later step (E21) between the first two.
#
# Booked returns are transactions labelled "Interest" or "Dividend" on the
# person's taxable accounts (Account::Taxation), from 1 January up to
# `as_of`. Amounts are converted into the profile's currency on their date.
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

  Income = Data.define(:account_id, :date, :kind, :amount)
  Bank = Data.define(:label, :allocation, :income, :accounts) do
    def remaining
      [ allocation - income, 0 ].max
    end

    def used_up?
      allocation.positive? && income >= allocation
    end
  end

  attr_reader :user, :year, :as_of, :profile, :unconvertible_count

  # One estimate per person, computed once: callers that need several
  # accounts of the same people (forecast, budget) share them.
  def self.cache
    Hash.new { |hash, (user, year)| hash[[ user, year ]] = new(user, year: year) }
  end

  # `viewer` (one user or several) limits the accounts to those every one of
  # them can see, for figures shown to someone else (the household budget,
  # family-wide insights).
  def initialize(user, year:, as_of: nil, viewer: nil)
    @user = user
    @year = year
    @viewer = viewer
    today = Account.liquidity_today_for(user&.family)
    @as_of = as_of || [ Date.new(year, 12, 31), today ].min
    @profile = TaxProfile.for(user, year)
    @unconvertible_count = 0
  end

  def profile?
    profile.present?
  end

  def currency
    profile&.currency || user&.family&.currency
  end

  # The person's accounts whose returns are taxable.
  def accounts
    @accounts ||= if user.nil?
      []
    else
      scope = user.family.accounts.visible.where(owner_id: user.id, accountable_type: Account::Taxation::TAXABLE_TYPES)
      Array(@viewer).each do |viewer|
        scope = scope.where(id: Account.accessible_by(viewer).select(:id)) unless viewer == user
      end
      scope.includes(:accountable).to_a.select(&:returns_taxable?)
    end
  end

  def withheld?(account)
    withheld_ids.include?(account.id)
  end

  def incomes
    @incomes ||= load_incomes
  end

  def income_total(kind: nil, account: nil)
    sum(incomes.select { |income| (kind.nil? || income.kind == kind) && (account.nil? || income.account_id == account.id) })
  end

  # Exemption orders given to banks with a withholding account.
  def allocated_allowance
    @allocated_allowance ||= accounts.select { |account| withheld?(account) }.sum { |account| account.tax_allowance_allocation.to_d }
  end

  def over_allocated?
    profile&.annual_allowance.present? && allocated_allowance > profile.annual_allowance
  end

  # What the deferred accounts can still use: the allowance no bank holds.
  def deferred_allowance
    [ (profile&.allowance || 0) - allocated_allowance, 0 ].max
  end

  def deferred_tax
    @deferred_tax ||= tax_on(incomes.reject { |income| withheld_ids.include?(income.account_id) }, deferred_allowance)
  end

  def withheld_tax
    @withheld_tax ||= accounts.select { |account| withheld?(account) }.sum do |account|
      tax_on(incomes.select { |income| income.account_id == account.id }, account.tax_allowance_allocation.to_d)
    end
  end

  # Kinds with booked returns but no rate in the profile: the estimate leaves
  # them out and says so.
  def missing_rates
    return [] unless profile?

    incomes.map(&:kind).uniq.select { |kind| profile.rate_for(kind).nil? }
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
  # booked there used of it.
  def banks
    @banks ||= accounts.select { |account| withheld?(account) && account.tax_allowance_allocation.to_d.positive? }
                       .group_by(&:tax_institution_label)
                       .map do |label, bank_accounts|
      Bank.new(
        label: label,
        allocation: bank_accounts.sum { |account| account.tax_allowance_allocation.to_d },
        income: bank_accounts.sum { |account| [ income_total(account: account), 0 ].max },
        accounts: bank_accounts
      )
    end.sort_by(&:label)
  end

  # The tax a further return of `amount` (in the account's currency, of
  # `kind`) would bear on `account`, after what is left of its allowance.
  # Nil when the person has no rate for it or the account is not theirs.
  def tax_for(account, amount, kind:)
    rate = profile&.rate_for(kind)
    return nil if rate.nil? || !account.returns_taxable? || account.owner_id != user&.id

    money = Money.new(amount, account.currency)
    converted = money.exchange_to(currency, date: as_of).amount
    taxable = [ converted - remaining_allowance_for(account), 0 ].max
    Money.new(taxable * rate / 100, currency).exchange_to(account.currency, date: as_of).amount.round(2)
  rescue Money::ConversionError
    nil
  end

  private
    def withheld_ids
      @withheld_ids ||= accounts.select { |account| account.tax_withheld_at_source_in?(year) }.map(&:id).to_set
    end

    def remaining_allowance_for(account)
      if withheld?(account)
        [ account.tax_allowance_allocation.to_d - income_total(account: account), 0 ].max
      else
        # Counted like `tax_on` does: positive returns of kinds with a rate.
        used = sum(incomes.select { |income| !withheld_ids.include?(income.account_id) && income.amount.positive? && profile&.rate_for(income.kind) })
        [ deferred_allowance - used, 0 ].max
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
        converted = Money.new(-amount, entry_currency).exchange_to(currency, date: date).amount
        Income.new(account_id: account_id, date: date, kind: INCOME_LABELS.fetch(label), amount: converted)
      rescue Money::ConversionError
        @unconvertible_count += 1
        nil
      end
    end
end
