class BalanceSheet::ClassificationGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :classification, :currency

  def initialize(classification:, currency:, accounts:)
    @classification = normalize_classification!(classification)
    @name = name
    @currency = currency
    @accounts = accounts
  end

  def name
    I18n.t("pages.dashboard.balance_sheet.classifications.#{classification}", default: classification.titleize.pluralize)
  end

  def icon
    classification == "asset" ? "plus" : "minus"
  end

  # Accounts that count towards totals: included in the viewer's finances and
  # not excluded from reports. Account groups use the same rule.
  def self.counted_accounts(accounts)
    accounts.select { |a| a.respond_to?(:included_in_finances?) ? a.included_in_finances? : true }
            .reject { |a| a.respond_to?(:exclude_from_reports?) && a.exclude_from_reports? }
  end

  def total
    self.class.counted_accounts(accounts).sum(&:converted_balance)
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  # Groups by account type unless another dimension is given (see
  # AccountGrouping). The split into assets and debts always stays above.
  # With the manual account order, the user's saved order of this
  # dimension's groups comes first; the rest keep their usual order.
  def account_groups(by: nil, user: nil)
    dimension = by.presence&.to_s || AccountGrouping::DEFAULT_PRIMARY
    groups = dimension == AccountGrouping::DEFAULT_PRIMARY ? type_groups : dimension_groups(dimension, user: user)
    return groups unless user&.account_order&.manual?

    BalanceSheet::ManualOrder.sort(groups, user.manual_list_positions("groups", dimension), &:key)
  end

  private
    attr_reader :accounts

    def type_group(accountable_type, account_rows)
      accountable = Accountable.from_type(accountable_type)

      BalanceSheet::AccountGroup.new(
        name: accountable.display_name,
        color: accountable.color,
        accountable_type: accountable,
        accounts: account_rows,
        classification_group: self
      )
    end

    # Sorted by the manual order defined by Accountable::TYPES so that the UI
    # displays account groups in a predictable, domain-specific sequence.
    def type_groups
      accounts.group_by(&:accountable_type)
              .map { |accountable_type, account_rows| type_group(accountable_type, account_rows) }
              .sort_by { |group| Accountable::TYPES.index(group.key.camelize) || Float::INFINITY }
    end

    def dimension_groups(dimension, user:)
      AccountGrouping.new(dimension, user: user).group(accounts_in_order_of(dimension, user: user)).map do |group|
        next type_group(group.key.accountable_type, group.accounts) if group.key.is_a?(AccountGrouping::TypeFallback)

        # Prefixed so an asset and a debt group with the same value stay apart.
        key = "#{classification}_#{AccountGrouping.group_key(dimension, group.key)}"

        BalanceSheet::AccountGroup.new(
          key: key,
          name: group.name,
          color: AccountGrouping.color_for(key),
          accountable_type: nil,
          accounts: group.accounts,
          classification_group: self
        )
      end
    end

    # The manual order is saved per account type for the account type
    # grouping (already applied to the accounts) and per dimension for the
    # others; accounts not placed yet follow by name.
    def accounts_in_order_of(dimension, user:)
      return accounts unless user&.account_order&.manual?

      by_name = accounts.sort_by { |account| [ account.name.to_s.downcase, account.id.to_s ] }
      BalanceSheet::ManualOrder.sort(by_name, user.manual_list_positions("accounts", dimension), &:id)
    end

    def normalize_classification!(classification)
      raise ArgumentError, "Invalid classification: #{classification}" unless %w[asset liability].include?(classification)
      classification
    end
end
