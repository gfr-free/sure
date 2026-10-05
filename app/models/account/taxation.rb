# How an account is taxed (taxes on returns, decision E20, STEUER.md S-1/S-2).
#
# - The tax treatment comes from TaxTreatable: investment accounts take it
#   from the subtype, crypto and (new) bank accounts store it.
# - `tax_withheld_at_source`: whether the bank books returns net (it pays the
#   tax) or gross (the tax is due later, S3). Nil follows the owner's profile.
# - `tax_allowance_allocation`: the share of the owner's allowance given to
#   this account's bank (exemption order).
# - `january_tax_debit`: a tax debited every January, such as the German
#   Vorabpauschale (S7). It shows up in the account forecast.
#
# Tax belongs to a person, not the family (S4): the account's owner. Joint
# accounts follow the owner until loss pots bring a per-account split (E21 T1).
# The arithmetic lives in Tax::Estimate.
module Account::Taxation
  extend ActiveSupport::Concern

  TAXABLE_TYPES = %w[Depository Investment Crypto].freeze
  WITHHELD_CHOICES = %w[profile yes no].freeze
  JANUARY_TAX_DEBIT_DAY = 2

  included do
    validates :tax_allowance_allocation, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
    validates :january_tax_debit, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

    before_validation :apply_tax_treatment_choice
  end

  attr_reader :tax_treatment_choice

  # Bank accounts store their treatment on the accountable; the account form
  # writes it through this attribute so it stays one form. Blank follows the
  # subtype.
  def tax_treatment_choice=(value)
    @tax_treatment_choice = value.to_s
  end

  def tax_capable?
    accountable_type.in?(TAXABLE_TYPES)
  end

  # Returns on this account count for the owner's tax: a capable account
  # whose treatment is taxable (nil reads as taxable, see TaxTreatable).
  def returns_taxable?
    tax_capable? && taxable?
  end

  def tax_person
    owner
  end

  def tax_profile_for(year)
    TaxProfile.for(tax_person, year)
  end

  # Whether the bank books returns net. Without the account's own setting
  # the owner's profile decides; without a profile, banks are assumed to
  # withhold, which keeps every figure gross as before.
  def tax_withheld_at_source_in?(year)
    return tax_withheld_at_source unless tax_withheld_at_source.nil?

    profile = tax_profile_for(year)
    profile.nil? || profile.withheld_at_source_default
  end

  def tax_withheld_choice
    case tax_withheld_at_source
    when true then "yes"
    when false then "no"
    else "profile"
    end
  end

  def tax_withheld_choice=(value)
    self.tax_withheld_at_source = case value.to_s
    when "yes" then true
    when "no" then false
    end
  end

  # The January debit falling on or after `from` and on or before `to`.
  def january_tax_debits_between(from, to)
    return [] unless january_tax_debit.to_d.positive?

    (from.year..to.year).filter_map do |year|
      date = Date.new(year, 1, JANUARY_TAX_DEBIT_DAY)
      date if date >= from && date <= to
    end
  end

  # Where the exemption order sits: the bank's name, else the account's.
  def tax_institution_label
    institution_name.presence || provider&.institution_name.presence || name
  end

  private
    def apply_tax_treatment_choice
      return if @tax_treatment_choice.nil?
      return unless accountable.is_a?(Depository)

      accountable.tax_treatment = @tax_treatment_choice.presence_in(Depository::TAX_TREATMENTS)
    end
end
