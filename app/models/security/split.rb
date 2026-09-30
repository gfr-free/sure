# A stock split (or reverse split) of a security, effective from `date`.
#
# `ratio_from` old shares became `ratio_to` new shares, so a 1:4 split turns
# 10 shares into 40. Splits a price provider reports have no family and apply
# everywhere; a family's own entries apply to that family only, because
# securities are shared across families and one family's typo must not move
# another family's holdings.
class Security::Split < ApplicationRecord
  SOURCES = %w[provider manual].freeze

  belongs_to :security
  belongs_to :family, optional: true

  validates :date, presence: true
  validates :ratio_from, :ratio_to, presence: true, numericality: { greater_than: 0 }
  validates :source, inclusion: { in: SOURCES }
  validates :date, uniqueness: { scope: %i[security_id family_id] }
  validate :ratio_changes_share_count
  validate :date_not_in_future

  scope :visible_to, ->(family) { where(family_id: [ nil, family&.id ]) }
  scope :chronological, -> { order(:date) }

  # Set when the caller enqueues one recalculation for a batch of splits.
  attr_accessor :skip_apply_job

  after_commit :apply_to_holdings_later, on: %i[create update destroy]

  # Accounts whose holdings a split of this security changes: all of them for
  # a provider split, only the family's own for a family's split.
  def self.affected_accounts(security:, family_id:)
    trade_account_ids = Entry.where(entryable_type: "Trade", entryable_id: security.trades.select(:id)).select(:account_id)
    holding_account_ids = Holding.where(security_id: security.id).select(:account_id)

    accounts = Account.where(id: trade_account_ids).or(Account.where(id: holding_account_ids))
    family_id ? accounts.where(family_id: family_id) : accounts
  end

  # A family's split changes every family account holding the security, so
  # only someone who may edit all of those accounts may add or remove one.
  def self.manageable_by?(user:, family:, security:)
    affected_accounts(security: security, family_id: family.id)
      .all? { |account| account.permission_for(user).in?(%i[owner full_control]) }
  end

  # How many new shares one old share became.
  def factor
    ratio_to.to_d / ratio_from.to_d
  end

  def manual?
    source == "manual"
  end

  private
    def ratio_changes_share_count
      return if ratio_from.blank? || ratio_to.blank?

      errors.add(:ratio_to, :same_as_ratio_from) if ratio_from.to_d == ratio_to.to_d
    end

    def date_not_in_future
      return if date.blank?

      errors.add(:date, :in_future) if date > Date.current
    end

    # A split rewrites every holding before its date, so the affected accounts
    # need a full recalculation, not just the days after the split.
    def apply_to_holdings_later
      return if skip_apply_job
      return if !destroyed? && !saved_change_to_date? && !saved_change_to_ratio_from? && !saved_change_to_ratio_to?

      split_dates = [ date, date_before_last_save ].compact.uniq
      SecuritySplitAppliedJob.perform_later(
        security_id: security_id,
        family_id: family_id,
        split_date: split_dates.min.iso8601
      )
    end
end
