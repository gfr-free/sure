module CustomAccountSubtypesHelper
  # Templates for a new custom subtype, grouped by account type: the bare
  # type first ("Type:"), then each built-in subtype ("Type:subtype").
  def custom_account_subtype_template_options
    Accountable::TYPES.map do |accountable_type|
      klass = Accountable.from_type(accountable_type)
      options = [ [ t("custom_account_subtypes.form.template_type_only", type: klass.singular_display_name), "#{accountable_type}:" ] ]
      options += klass::SUBTYPES.keys.map { |subtype| [ klass.long_subtype_label_for(subtype), "#{accountable_type}:#{subtype}" ] }

      [ klass.display_name, options ]
    end
  end

  # One line of what the subtype sets: "Locked until a date · Tax-Deferred".
  def custom_account_subtype_rules_summary(custom_account_subtype)
    parts = [ t("accounts.liquidity.levels.#{custom_account_subtype.liquidity}") ]
    if custom_account_subtype.tax_treatment_supported? && custom_account_subtype.tax_treatment
      parts << t("accounts.tax_treatments.#{custom_account_subtype.tax_treatment}")
    end
    safe_join(parts, " · ")
  end

  # The family's own subtypes that fit the account's type, for the account form.
  def custom_account_subtype_options(account)
    return [] if account.accountable_type.blank?

    Current.family.custom_account_subtypes
      .for_accountable_type(account.accountable_type)
      .alphabetically
      .map { |custom_subtype| [ custom_subtype.name, custom_subtype.id ] }
  end

  # Custom subtype id => default availability, so the availability select can
  # follow a change of the custom subtype before saving.
  def custom_account_subtype_liquidity_defaults(account)
    return {} if account.accountable_type.blank?

    Current.family.custom_account_subtypes
      .for_accountable_type(account.accountable_type)
      .to_h { |custom_subtype| [ custom_subtype.id, custom_subtype.liquidity ] }
  end
end
