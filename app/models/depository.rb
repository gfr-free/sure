class Depository < ApplicationRecord
  include Accountable

  DEFAULT_SUBTYPE = "checking"

  SUBTYPES = {
    "cash" => { short: "Cash", long: "Cash" },
    "checking" => { short: "Checking", long: "Checking" },
    "savings" => { short: "Savings", long: "Savings" },
    "hsa" => { short: "HSA", long: "Health Savings Account" },
    "cd" => { short: "CD", long: "Certificate of Deposit" },
    "money_market" => { short: "MM", long: "Money Market" },
    "notice_savings" => { short: "Notice Savings", long: "Notice Savings Account" },
    "building_savings" => { short: "Building Savings", long: "Building Savings Contract" }
  }.freeze

  # Default availability per subtype (Account::Liquidity). Subtypes not listed
  # are immediate.
  LIQUIDITY_BY_SUBTYPE = {
    "money_market" => "short_term",
    "notice_savings" => "short_term",
    "cd" => "locked",
    "building_savings" => "locked",
    "hsa" => "long_term"
  }.freeze

  # Depository subtypes that carry tax-advantaged treatment in the budget /
  # cashflow / income-statement filters (`Family#tax_advantaged_account_ids`,
  # `TaxTreatable#tax_advantaged?`). HSA cash sits here because Plaid routes
  # `depository.hsa` to `Depository` (not `Investment`) via
  # `PlaidAccount::TypeMappable`, so a real-world Plaid-linked HSA cash account
  # was previously invisible to the tax-advantaged filter PR #724 introduced.
  TAX_ADVANTAGED_SUBTYPES = %w[hsa].freeze

  TAX_TREATMENTS = %w[taxable tax_deferred tax_exempt tax_advantaged].freeze

  validate :stored_tax_treatment_must_be_known

  # `TaxTreatable` (the `Account` concern) reads this via `respond_to?`.
  #
  # The `tax_treatment` column (taxes on returns, decision E20 S2) holds the
  # person's choice, such as a tax-exempt savings wrapper. Without one the
  # subtype decides: HSA cash is tax-advantaged, every other subtype returns
  # `nil` (not `:taxable`). `nil` already reads as taxable everywhere it
  # matters: `TaxTreatable#taxable?` treats `nil` as taxable and
  # `#tax_advantaged?` excludes it. Returning `nil` also keeps
  # `tax_treatment.present?` false so the header tax badge
  # (`app/views/accounts/show/_header.html.erb`) stays hidden on checking,
  # savings, CD, and money-market accounts that never displayed it before.
  def tax_treatment
    stored = self[:tax_treatment]
    return stored.to_sym if stored.present?

    self.class.default_tax_treatment_for(subtype)
  end

  def tax_treatment=(value)
    self[:tax_treatment] = value.presence
  end

  class << self
    def default_liquidity_for(subtype)
      LIQUIDITY_BY_SUBTYPE.fetch(subtype.to_s, "immediate")
    end

    def default_tax_treatment_for(subtype)
      :tax_advantaged if TAX_ADVANTAGED_SUBTYPES.include?(subtype)
    end

    def color
      "#875BF7"
    end

    def classification
      "asset"
    end

    def icon
      "landmark"
    end
  end

  private
    # The reader falls back to the subtype, so validate the stored value.
    def stored_tax_treatment_must_be_known
      stored = self[:tax_treatment]
      errors.add(:tax_treatment, :inclusion) if stored.present? && !stored.in?(TAX_TREATMENTS)
    end
end
