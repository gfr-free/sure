# Account choices for rule conditions and actions. Rules are family-wide, so a
# rule may point at an account the viewer can't access: only accessible
# accounts are offered or accepted, and a stored one the viewer can't access
# shows under a neutral label instead of its name.
module Rule::AccountValue
  def options
    accessible_accounts.alphabetically.pluck(:name, :id)
  end

  # Keeping the stored account as an option means saving the form doesn't
  # silently switch it to the first account in the list.
  def options_for(value)
    visible = options
    return visible if value.blank? || visible.any? { |_name, id| id.to_s == value.to_s }
    return visible unless family.accounts.exists?(id: value)

    [ [ I18n.t("rule.account_not_shared"), value.to_s ], *visible ]
  end

  # Without a signed-in user (jobs, imports) there is no viewer to check.
  def selectable_value?(value)
    Current.user.nil? || accessible_accounts.exists?(id: value)
  end

  private
    def accessible_accounts
      family.accounts.accessible_by(Current.user)
    end
end
