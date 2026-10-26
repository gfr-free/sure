# Account choices for rule conditions and actions. Rules are family-wide, so a
# rule may point at an account the viewer can't access: only accounts the
# viewer may choose are offered or accepted, and a stored one they can't see
# shows under a neutral label instead of its name.
module Rule::AccountValue
  def options
    choosable_accounts.alphabetically.pluck(:name, :id)
  end

  # Keeping the stored account as an option means saving the form doesn't
  # silently switch it to the first account in the list.
  def options_for(value)
    visible = options
    return visible if value.blank? || visible.any? { |_name, id| id.casecmp?(value.to_s) }

    name = accessible_accounts.where(id: value).pick(:name) if Rule::AccountValue.uuid?(value)
    [ [ name || I18n.t("rule.account_not_shared"), value.to_s ], *visible ]
  end

  # Without a signed-in user (jobs, imports) there is no viewer to check.
  def selectable_value?(value)
    Current.user.nil? || (Rule::AccountValue.uuid?(value) && choosable_accounts.exists?(id: value))
  end

  def self.uuid?(value)
    value.to_s.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
  end

  private
    def choosable_accounts
      accessible_accounts
    end

    # Mailers and jobs render without a viewer; they name no account.
    def accessible_accounts
      Current.user ? family.accounts.accessible_by(Current.user) : family.accounts.none
    end
end
