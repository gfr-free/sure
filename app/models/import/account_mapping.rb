class Import::AccountMapping < Import::Mapping
  validates :mappable, presence: true, if: :requires_mapping?

  class << self
    # Existing accounts rows can go into: those the current user may write
    # to, or the whole family when no user is acting (jobs, console).
    def target_accounts_for(import)
      accounts = import.family.accounts
      Current.user ? accounts.writable_by(Current.user) : accounts
    end

    def mappables_by_key(import)
      unique_values = import.rows.map(&:account).uniq
      accounts = target_accounts_for(import).where(name: unique_values).index_by(&:name)

      unique_values.index_with { |value| accounts[value] }
    end
  end

  def selectable_values
    family_accounts = self.class.target_accounts_for(import).manual.alphabetically.map { |account| [ account.name, account.id ] }

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
