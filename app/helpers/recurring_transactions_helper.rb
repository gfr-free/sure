module RecurringTransactionsHelper
  def frequency_label(recurring_transaction)
    RecurringTransaction::FrequencyPreset.label(recurring_transaction)
  end

  # Status is domain state; the tone is how the design system says it. The
  # mapping lives here so every surface badges a status the same way.
  def recurring_status_pill_tone(status)
    case status.to_s
    when "active"    then :success
    when "suggested" then :warning
    else :neutral
    end
  end

  # Which of these accounts are manual, for the bill form's auto-post switch.
  # One query instead of Account#manual? per option.
  def recurring_manual_account_ids(accounts)
    accounts.reorder(nil).manual.pluck(:id)
  end

  # Writable accounts only, since a posted transfer writes into the
  # destination too. The current destination stays listed even when the user
  # could not pick it, so saving the form does not silently clear it.
  def recurring_destination_options(recurring_transaction)
    options = Current.family.accounts.writable_by(Current.user).visible.alphabetically.to_a
    current = recurring_transaction.destination_account
    options << current if current && options.exclude?(current)
    options
  end

  # Same idea for the merchant: a detected one may no longer be in the list
  # the user can pick from.
  def recurring_merchant_options(recurring_transaction)
    options = Current.family.available_merchants_for(Current.user).alphabetically.to_a
    current = recurring_transaction.merchant
    options << current if current && options.exclude?(current)
    options
  end

  def frequency_preset_options(recurring_transaction)
    options = RecurringTransaction::FrequencyPreset::PRESETS.map do |preset|
      [ t("recurring_transactions.frequency_presets.#{preset}"), preset ]
    end

    # The two custom options sit together after the named presets: "keep this
    # schedule" only when the picker cannot express it, then "set my own".
    if RecurringTransaction::FrequencyPreset.detect(recurring_transaction).key == RecurringTransaction::FrequencyPreset::CUSTOM
      options << [ t("recurring_transactions.frequency_presets.custom"), RecurringTransaction::FrequencyPreset::CUSTOM ]
    end

    options << [ t("recurring_transactions.frequency_presets.interval"), RecurringTransaction::FrequencyPreset::INTERVAL ]
  end

  def frequency_interval_unit_options
    RecurringTransaction::FrequencyPreset::INTERVAL_UNITS.map do |unit|
      [ t("recurring_transactions.frequency_interval_units.#{unit}"), unit ]
    end
  end

  def frequency_day_options
    # localized_ordinal, not ordinalize: the bare Rails helper always emits
    # English suffixes regardless of the active locale.
    (1..31).map { |day| [ localized_ordinal(day), day ] } +
      [ [ t("recurring_transactions.frequency.last_day"), RecurrenceRule::LAST ] ]
  end

  def frequency_weekday_options
    t("date.day_names").each_with_index.map { |name, index| [ name, index ] }
  end

  def frequency_month_options
    t("date.month_names").compact.each_with_index.map { |name, index| [ name, index + 1 ] }
  end
end
