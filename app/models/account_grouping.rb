# Second grouping level for account lists (sidebar, dashboard balance sheet).
#
# The first level stays the account type. Within each type group the accounts
# can be split by one dimension the user picks per view. Every dimension maps
# an account to exactly one value, so the subgroup totals always add up to the
# type group total. Accounts without a value land in a trailing "Not set" group,
# whose key is nil so it can never collide with a real value.
class AccountGrouping
  VIEWS = %w[sidebar dashboard].freeze
  DIMENSIONS = %w[subtype institution connection owner ownership currency tax_treatment custom_group].freeze
  CUSTOM_GROUP_MAX_LENGTH = 50

  Group = Data.define(:key, :name, :accounts)

  attr_reader :dimension, :user

  class << self
    def valid_dimension?(key)
      DIMENSIONS.include?(key.to_s)
    end

    def dimension_label(key, user: nil)
      return user.custom_account_group_label if key.to_s == "custom_group" && user

      I18n.t("account_grouping.dimensions.#{key}")
    end

    # Collapses case and whitespace so "ING", " ing " and "Ing" share a group.
    def normalize(value)
      value.to_s.squish.downcase.presence
    end
  end

  def initialize(dimension, user:)
    raise ArgumentError, "Invalid grouping dimension: #{dimension}" unless self.class.valid_dimension?(dimension)

    @dimension = dimension.to_s
    @user = user
  end

  # Splits the given (already sorted) accounts into subgroups. Account order
  # inside each subgroup is preserved; subgroups are sorted by name with the
  # "Not set" group last.
  def group(accounts)
    accounts.group_by { |account| value_key_for(account) }
            .map { |key, rows| Group.new(key: key, name: name_for(key, rows.first), accounts: rows) }
            .sort_by { |group| [ group.key.nil? ? 1 : 0, group.name.downcase ] }
  end

  private
    def value_key_for(account)
      value = case dimension
      when "subtype" then account.subtype.presence
      when "institution" then self.class.normalize(account.institution_name)
      when "connection" then account.provider_name.presence || "manual"
      when "owner" then account.owner_id
      when "ownership" then ownership_for(account)
      when "currency" then account.currency.presence
      when "tax_treatment" then account.tax_treatment&.to_s
      when "custom_group" then self.class.normalize(account.custom_group)
      end

      value.presence
    end

    def name_for(key, account)
      return I18n.t("account_grouping.none") if key.nil?

      case dimension
      when "subtype" then account.long_subtype_label
      when "institution" then account.institution_name.to_s.squish
      when "connection" then I18n.t("account_grouping.connections.#{key}", default: key.to_s.titleize)
      when "owner" then account.owner&.display_name || I18n.t("account_grouping.none")
      when "ownership" then I18n.t("account_grouping.ownership.#{key}")
      when "currency" then key
      when "tax_treatment" then account.tax_treatment_label
      when "custom_group" then account.custom_group.to_s.squish
      end
    end

    def ownership_for(account)
      return nil if account.owner_id.nil? || user.nil?

      account.owner_id == user.id ? "mine" : "shared_with_me"
    end
end
