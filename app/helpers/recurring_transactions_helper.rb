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
  # One query instead of Account#manual? per option. The bill's own account
  # counts even when the picker hides it (a disabled account), so saving the
  # form does not switch auto-posting off behind the user's back.
  def recurring_manual_account_ids(accounts, current: nil)
    ids = accounts.reorder(nil).manual.pluck(:id)
    ids << current.id if current&.manual?
    ids.uniq
  end

  # Discarding a post deletes its entry, and both legs of a transfer, so it
  # takes write access to every account involved, as
  # RecurringAllocationsController#ensure_posted_entries_writable checks.
  def auto_post_discardable?(allocation, writable_account_ids)
    series = allocation.recurring_occurrence.recurring_transaction
    [ allocation.entry&.account_id, series.account_id, series.destination_account_id ].compact.all? { |id| writable_account_ids.include?(id) }
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
