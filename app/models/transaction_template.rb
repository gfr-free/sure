# A reusable set of values for the New transaction form. Templates belong to
# the family; the account, merchant and tags are applied only where the
# person filling the form can see them.
class TransactionTemplate < ApplicationRecord
  belongs_to :family
  belongs_to :account, optional: true
  belongs_to :category, optional: true
  # Family merchants only: they are visible to every member, unlike provider
  # merchants, which follow account sharing.
  belongs_to :merchant, class_name: "FamilyMerchant", optional: true
  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, through: :taggings

  enum :nature, { outflow: "outflow", inflow: "inflow" }, validate: true

  normalizes :name, with: ->(name) { name.strip }

  validates :name, presence: true, length: { maximum: 255 }
  validates :amount, numericality: { greater_than: 0 }, allow_nil: true
  validates :currency, presence: true, if: -> { amount.present? }
  validate :references_belong_to_family

  scope :alphabetically, -> { order(Arel.sql("LOWER(transaction_templates.name)"), :created_at) }

  # Copies a saved manual transaction. A provider merchant is left out, see
  # the merchant association above.
  def self.build_from_entry(entry)
    transaction = entry.transaction

    new(
      family: entry.account.family,
      name: entry.name,
      nature: entry.amount.negative? ? "inflow" : "outflow",
      amount: entry.amount.abs,
      currency: entry.currency,
      account: entry.account,
      category_id: transaction.category_id,
      merchant_id: transaction.merchant.is_a?(FamilyMerchant) ? transaction.merchant_id : nil,
      notes: entry.notes,
      tag_ids: transaction.tag_ids
    )
  end

  def account_for(user)
    account if account && Account.accessible_by(user).manual.active.exists?(id: account.id)
  end

  # Attributes for a new Entry and its Transaction.
  def entry_attributes_for(user)
    visible_account = account_for(user)

    {
      name: name,
      amount: amount,
      currency: amount.present? ? currency : visible_account&.currency,
      notes: notes,
      entryable: {
        category_id: category_id,
        merchant_id: merchant_id,
        tag_ids: tag_ids
      }
    }.compact
  end

  private
    def references_belong_to_family
      errors.add(:account, :invalid) if account && account.family_id != family_id
      errors.add(:category, :invalid) if category && category.family_id != family_id
      errors.add(:merchant, :invalid) if merchant && merchant.family_id != family_id
      errors.add(:tags, :invalid) if tags.any? { |tag| tag.family_id != family_id }
    end
end
