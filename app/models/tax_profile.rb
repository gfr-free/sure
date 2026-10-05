# A person's tax settings for returns (liquidity concept, decision E20,
# STEUER.md S1-S10). Per person, not per family: partners often have
# different situations, and exemption orders run on persons (S4).
#
# A rate per income type (S1), a yearly allowance and whether the person's
# banks usually withhold the tax (S3). Every value is entered by the person;
# Sure has no country presets (S5) and no church tax (S10): whoever needs it
# enters a higher rate. Rates are in percent.
#
# A profile applies from `valid_from_year` until the next one, so a new rate
# does not rewrite earlier years.
class TaxProfile < ApplicationRecord
  INCOME_KINDS = %w[interest dividends gains crypto].freeze
  MIN_YEAR = 1990
  MAX_YEAR = 2200

  belongs_to :user

  validates :valid_from_year, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: MIN_YEAR, less_than_or_equal_to: MAX_YEAR },
            uniqueness: { scope: :user_id }
  validates :currency, presence: true
  validates(*INCOME_KINDS.map { |kind| :"rate_#{kind}" },
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true)
  validates :annual_allowance, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :currency_must_be_known

  scope :chronological, -> { order(:valid_from_year) }

  # The profile in force in `year`: the latest one that starts on or before it.
  def self.for(user, year)
    return nil if user.nil?

    user.tax_profiles.where(valid_from_year: ..year).order(valid_from_year: :desc).first
  end

  # The rate for an income kind in percent, nil when the person left it empty.
  def rate_for(kind)
    raise ArgumentError, "unknown income kind #{kind}" unless kind.to_s.in?(INCOME_KINDS)

    public_send(:"rate_#{kind}")
  end

  def rates?
    INCOME_KINDS.any? { |kind| rate_for(kind).present? }
  end

  def allowance
    annual_allowance || 0.to_d
  end

  private
    def currency_must_be_known
      return if currency.blank?

      Money::Currency.new(currency)
    rescue Money::Currency::UnknownCurrencyError
      errors.add(:currency, :inclusion)
    end
end
