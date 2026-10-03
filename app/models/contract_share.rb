# Per-user access to a contract the user does not own. Mirrors AccountShare:
# the owner decides who sees a contract, and admins get no implicit access.
class ContractShare < ApplicationRecord
  belongs_to :contract
  belongs_to :user

  PERMISSIONS = %w[full_control read_write read_only].freeze
  EDIT_PERMISSIONS = %w[full_control read_write].freeze

  validates :permission, inclusion: { in: PERMISSIONS }
  validates :user_id, uniqueness: { scope: :contract_id }
  validate :cannot_share_with_owner
  validate :user_in_same_family
  validate :guests_read_only

  def full_control?
    permission == "full_control"
  end

  def read_write?
    permission == "read_write"
  end

  def read_only?
    permission == "read_only"
  end

  private

    def cannot_share_with_owner
      return unless contract && user && contract.owner_id == user_id

      errors.add(:user, :owner)
    end

    def user_in_same_family
      return unless contract && user && user.family_id != contract.family_id

      errors.add(:user, :other_family)
    end

    # Guests reach the app through a chat-only layout; they may read a contract
    # someone shares with them but never change it.
    def guests_read_only
      return unless user&.guest? && !read_only?

      errors.add(:permission, :guest_read_only)
    end
end
