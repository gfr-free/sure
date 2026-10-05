# One entry in an account's interest rate history (liquidity concept, decision
# E18). An entry applies from `effective_from` until the next entry of the same
# kind, so a planned change, such as a teaser rate that ends, is simply an
# entry dated in the future.
#
# `applies_to` separates the credit rate (paid on a positive balance) from the
# debit rate (charged on an overdraft). Rates are nominal, in percent per year.
class Account::InterestRate < ApplicationRecord
  self.table_name = "account_interest_rates"

  KINDS = %w[credit debit].freeze
  SOURCES = %w[manual provider].freeze
  MIN_RATE = -99
  MAX_RATE = 999

  belongs_to :account

  validates :effective_from, presence: true
  validates :rate, numericality: { greater_than_or_equal_to: MIN_RATE, less_than_or_equal_to: MAX_RATE }
  validates :applies_to, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :effective_from, uniqueness: { scope: [ :account_id, :applies_to ] }

  scope :credit, -> { where(applies_to: "credit") }
  scope :debit, -> { where(applies_to: "debit") }
  scope :chronological, -> { order(:effective_from) }
end
