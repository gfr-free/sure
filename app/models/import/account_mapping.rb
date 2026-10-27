class Import::AccountMapping < Import::Mapping
  validates :mappable, presence: true, if: :requires_mapping?

  class << self
    def mappables_by_key(import)
      unique_values = import.rows.map(&:account).uniq
      accounts = import.family.accounts.where(name: unique_values).index_by(&:name)

      unique_values.index_with { |value| accounts[value] }
    end
  end

  # Linked accounts are offered too: imported rows are deduplicated against
  # provider entries. Only accounts the user may write to, as publishing
  # requires write access to every mapped account.
  def selectable_values(user: Current.user)
    accounts = user ? import.family.accounts.writable_by(user).visible.alphabetically : Account.none
    family_accounts = accounts.map { |account| [ account.name, account.id ] }

    unless key.blank?
      family_accounts.unshift [ "Add as new account", CREATE_NEW_KEY ]
    end

    family_accounts
  end

  def requires_selection?
    true
  end

  def values_count
    import.rows.where(account: key).count
  end

  def mappable_class
    Account
  end

  def create_mappable!
    return unless creatable?

    account = import.family.accounts.create_or_find_by!(name: key) do |new_account|
      new_account.balance = 0
      new_account.import = import
      new_account.currency = import.family.currency
      new_account.accountable = Depository.new
    end

    self.mappable = account
    save!
  end

  private
    def requires_mapping?
      (key.blank? || !create_when_empty) && import.account.nil?
    end
end
