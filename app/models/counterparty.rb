# A person outside the household the user pays for or gets money from.
# Each person has one clearing account per currency (see Clearing); the
# account balances say who owes whom.
class Counterparty < ApplicationRecord
  belongs_to :family
  belongs_to :created_by, class_name: "User", optional: true

  has_many :clearings, dependent: :restrict_with_exception

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, length: { maximum: 100 }
  validates :default_currency, presence: true
  validates :name, uniqueness: { scope: :family_id, case_sensitive: false }
  validates :default_currency, inclusion: { in: ->(_) { Money::Currency.as_options.map(&:iso_code) } }

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :alphabetically, -> { order(Arel.sql("lower(counterparties.name)")) }

  # People whose clearing accounts the user can see, plus the ones the user
  # created and has not opened an account for yet.
  scope :visible_to, ->(user) {
    accessible_clearing_ids = Account.accessible_by(user).where(accountable_type: "Clearing").select(:accountable_id)
    where(family_id: user.family_id).where(
      "counterparties.created_by_id = :user_id OR counterparties.id IN (:counterparty_ids)",
      user_id: user.id,
      counterparty_ids: Clearing.where(id: accessible_clearing_ids).select(:counterparty_id)
    )
  }

  def accounts
    family.accounts.where(accountable_type: "Clearing", accountable_id: clearings.select(:id))
  end

  # The person's clearing account in `currency`, created on first use. Owned by
  # `user` and never shared automatically (see Account#auto_share_with_family!).
  def clearing_account_for!(currency, user:)
    with_lock do
      accounts.find_by(currency: currency) || family.accounts.create_and_sync({
        name: account_name_for(currency),
        currency: currency,
        balance: 0,
        owner: user,
        accountable: Clearing.new(counterparty: self)
      })
    end
  end

  # Whether `user` may book an entry in `currency` onto this person: they must
  # see the person, and may write to the clearing account that would get it.
  def assignable_by?(user, currency:)
    return false if archived? || user.nil?
    return false unless self.class.visible_to(user).exists?(id)

    account = accounts.find_by(currency: currency)
    account.nil? || AccountPolicy.new(user, account).update?
  end

  # Renaming, archiving and forgiving need write access to every clearing
  # account the person has (or, before the first one, being its creator).
  def manageable_by?(user)
    return false if user.nil? || user.family_id != family_id

    person_accounts = accounts.to_a
    return created_by_id == user.id if person_accounts.empty?

    person_accounts.all? { |account| AccountPolicy.new(user, account).update? }
  end

  def archived?
    archived_at.present?
  end

  # Archiving hides a person from pickers. Only a settled person can be
  # archived, so an open balance never drops out of sight.
  def archivable?
    !archived? && settled?
  end

  def settled?
    accounts.all? { |account| account.balance.zero? }
  end

  def archive!
    return false unless archivable?

    update!(archived_at: Time.current)
  end

  def unarchive!
    update!(archived_at: nil)
  end

  # Books the remaining balance of `account` as spending (the user forgives a
  # debt) or income (the person forgives the user's debt), so it reaches zero.
  def forgive!(account:, category: nil, date: Date.current)
    raise ArgumentError, "account does not belong to this person" unless accounts.exists?(account.id)
    return nil if account.balance.zero?

    entry = account.entries.create!(
      date: date,
      name: I18n.t("counterparties.forgiveness.entry_name", name: name),
      amount: account.balance,
      currency: account.currency,
      user_modified: true,
      entryable: Transaction.new(category: category)
    )
    entry.sync_account_later
    entry
  end

  private
    def account_name_for(currency)
      currency == default_currency ? name : "#{name} (#{currency})"
    end
end
