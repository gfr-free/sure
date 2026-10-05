# A loss pot on a securities or crypto account (taxes on returns, decision
# E21, STEUER.md section 4). Banks keep losses that were not yet offset in
# pots; Sure keeps one per kind and account (T4) and, in this first step
# (V-1), only the balance the person copies from a bank statement.
#
# - `stocks` holds losses from selling shares and offsets share gains only.
# - `general` holds every other loss and offsets every return.
#
# Countries without the split use the general pot alone. `carry_forward`
# says whether a balance survives the year end; without it a balance only
# counts in the year it was entered for.
class LossPot < ApplicationRecord
  KINDS = %w[stocks general].freeze
  ACCOUNT_TYPES = %w[Investment Crypto].freeze

  belongs_to :account
  has_many :snapshots, -> { order(:date) }, class_name: "LossPot::Snapshot", dependent: :destroy, inverse_of: :loss_pot

  validates :kind, inclusion: { in: KINDS }, uniqueness: { scope: :account_id }
  validate :account_can_hold_pots

  def stocks?
    kind == "stocks"
  end

  def latest_snapshot
    snapshots.loaded? ? snapshots.max_by(&:date) : snapshots.last
  end

  # The latest balance entered on or before `date`.
  def anchor_on(date)
    if snapshots.loaded?
      snapshots.select { |snapshot| snapshot.date <= date }.max_by(&:date)
    else
      snapshots.where(date: ..date).reorder(date: :desc).first
    end
  end

  # The balance that still counts at the start of the estimate for `year`,
  # with the date it was entered for. A balance from an earlier year only
  # counts when the pot carries forward, and only from the year before:
  # Sure does not roll balances forward (that is V-2), so an older one would
  # ignore everything in between. Amounts are in the account's currency.
  def opening_for(year, as_of:)
    anchor = anchor_on(as_of)
    return nil if anchor.nil? || outdated_for?(year, as_of: as_of)
    return nil if anchor.date.year < year && !carry_forward?

    anchor
  end

  # Whether the latest balance is too old to use for `year`: entered before
  # the end of the year before last, for a pot that carries forward.
  def outdated_for?(year, as_of:)
    anchor = anchor_on(as_of)
    anchor.present? && carry_forward? && anchor.date.year < year - 1
  end

  private
    def account_can_hold_pots
      errors.add(:account, :invalid) unless account&.accountable_type.in?(ACCOUNT_TYPES)
    end
end
