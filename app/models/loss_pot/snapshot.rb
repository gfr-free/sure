# A loss pot's balance on a date, as the bank statement shows it (V-1). The
# latest one is the anchor the tax estimate offsets later gains against.
class LossPot::Snapshot < ApplicationRecord
  SOURCES = %w[manual computed provider].freeze

  belongs_to :loss_pot, inverse_of: :snapshots

  validates :date, presence: true, uniqueness: { scope: :loss_pot_id }
  validates :amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :source, inclusion: { in: SOURCES }
end
