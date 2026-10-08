# A subtype a family defines itself for one account type ("Fixed deposit 2y",
# "Company pension"), together with the rules it brings. It can only combine
# rules that exist in code (Accountable::Rules); it cannot invent behaviour.
#
# An account that points at one takes its rules from here instead of from the
# built-in subtype. The built-in subtype stays on the accountable: provider
# syncs keep writing it, and it comes back into force when the custom subtype
# is removed from the account or deleted.
#
# The built-in subtypes serve as templates: `build_from_template` copies their
# rules into a new custom subtype.
class CustomAccountSubtype < ApplicationRecord
  # Account types whose tax treatment follows the subtype. Crypto keeps its
  # tax treatment in a column the user sets on the account, the other types
  # have none.
  TAX_TREATMENT_TYPES = %w[Depository Investment].freeze
  TAX_TREATMENTS = %w[taxable tax_deferred tax_exempt tax_advantaged].freeze
  TAX_ADVANTAGED_TREATMENTS = %w[tax_deferred tax_exempt tax_advantaged].freeze

  MAX_NAME_LENGTH = 64

  belongs_to :family
  has_many :accounts, dependent: nil # released in #release_accounts

  validates :accountable_type, inclusion: { in: Accountable::TYPES }
  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
  validates :name, uniqueness: { scope: [ :family_id, :accountable_type ], case_sensitive: false }
  validate :liquidity_must_be_known
  validate :tax_treatment_must_fit_type
  validate :accountable_type_fixed_while_in_use, on: :update

  before_validation :normalize_rules

  # Accounts that follow the rules move to the new default; a level the user
  # picked on the account stays.
  after_update_commit :refresh_account_liquidity, if: :saved_change_to_rules?
  # Caches keyed on the accounts' updated_at (sidebar labels, budget and
  # cash flow totals) see the new name and tax treatment.
  after_update_commit :touch_accounts, if: -> { saved_change_to_rules? || saved_change_to_name? }

  # The accounts fall back to their built-in subtype's rules, so their default
  # availability is written again before the reference goes.
  before_destroy :release_accounts

  scope :alphabetically, -> { order(Arel.sql("lower(name)")) }
  scope :for_accountable_type, ->(type) { where(accountable_type: type) }

  class << self
    # A new custom subtype that starts with the rules of a built-in subtype
    # (or of the bare account type when `subtype` is blank).
    def build_from_template(family:, accountable_type:, subtype: nil)
      klass = Accountable.from_type(accountable_type)
      return family.custom_account_subtypes.new(accountable_type: accountable_type) if klass.nil?

      rules = klass.rules_for(subtype)
      name = subtype.present? ? klass.long_subtype_label_for(subtype) : nil

      family.custom_account_subtypes.new(
        accountable_type: accountable_type,
        name: name,
        rules: { "liquidity" => rules.liquidity, "tax_treatment" => rules.tax_treatment&.to_s }.compact
      )
    end

    def tax_treatment_supported?(accountable_type)
      accountable_type.to_s.in?(TAX_TREATMENT_TYPES)
    end
  end

  def accountable_class
    Accountable.from_type(accountable_type)
  end

  def liquidity
    rules["liquidity"]
  end

  def liquidity=(value)
    self.rules = rules.merge("liquidity" => value.to_s.presence).compact
  end

  def tax_treatment
    rules["tax_treatment"]&.to_sym
  end

  def tax_treatment=(value)
    self.rules = rules.merge("tax_treatment" => value.to_s.presence).compact
  end

  def tax_treatment_supported?
    self.class.tax_treatment_supported?(accountable_type)
  end

  # The same shape the built-in subtypes produce, so callers do not care
  # where the rules come from.
  def to_rules
    Accountable::Rules.new(
      accountable_type: accountable_type,
      subtype: nil,
      liquidity: liquidity,
      tax_treatment: tax_treatment
    )
  end

  # Rules as plain data for the API, exports and the assistant.
  def rules_for_export
    { "liquidity" => liquidity, "tax_treatment" => tax_treatment&.to_s }
  end

  private
    # Only known keys are kept, so the column never carries stray input.
    def normalize_rules
      self.rules = (rules || {}).to_h.stringify_keys.slice("liquidity", "tax_treatment").compact_blank
      self.rules = rules.except("tax_treatment") unless tax_treatment_supported?
    end

    def liquidity_must_be_known
      return if liquidity.in?(Account::Liquidity::LEVELS)

      errors.add(:liquidity, :inclusion)
    end

    def tax_treatment_must_fit_type
      return if rules["tax_treatment"].nil? || rules["tax_treatment"].in?(TAX_TREATMENTS)

      errors.add(:tax_treatment, :inclusion)
    end

    # Accounts of another type would end up with rules that do not fit them.
    def accountable_type_fixed_while_in_use
      return unless will_save_change_to_accountable_type? && accounts.exists?

      errors.add(:accountable_type, :in_use)
    end

    def refresh_account_liquidity
      accounts.includes(:accountable).find_each { |account| account.refresh_default_liquidity!(keep_release_fields: true) }
    end

    def touch_accounts
      accounts.touch_all
    end

    def release_accounts
      # Columns only: an unrelated validation on an old account must not block
      # deleting the subtype.
      accounts.includes(:accountable).find_each do |account|
        account.update_columns(custom_account_subtype_id: nil, updated_at: Time.current)
        account.refresh_default_liquidity!(keep_release_fields: true)
      end
    end
end
