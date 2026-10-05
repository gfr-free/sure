# A family's own subtype on an account (CustomAccountSubtype). When set, its
# name is the account's subtype label and its rules replace the built-in
# subtype's (Account::Liquidity#subtype_rules, TaxTreatable#tax_treatment).
# The built-in subtype stays on the accountable underneath.
module Account::CustomSubtype
  extend ActiveSupport::Concern

  included do
    belongs_to :custom_account_subtype, optional: true

    validate :custom_account_subtype_must_fit
  end

  def custom_subtype?
    custom_account_subtype_id.present?
  end

  private
    def custom_account_subtype_must_fit
      return if custom_account_subtype_id.nil?
      # A subtype deleted while the form was open: a form error, not a
      # foreign key error.
      return errors.add(:custom_account_subtype, :invalid) if custom_account_subtype.nil?
      return if custom_account_subtype.family_id == family_id &&
        custom_account_subtype.accountable_type == accountable_type

      errors.add(:custom_account_subtype, :invalid)
    end
end
