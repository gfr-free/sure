class Rule::ActionExecutor::AppendTransactionNotes < Rule::ActionExecutor
  def label
    I18n.t("rules.action_executors.append_transaction_notes")
  end

  def type
    "text"
  end

  def options
    nil
  end

  # Appended lines add up like tags: several appending rules may each add
  # their line. A rule above that replaces the notes still wins, and an
  # append keeps replacing rules further down away (see SetTransactionNotes).
  def claimed_attributes
    [ :appended_notes ]
  end

  def blocking_attributes
    [ :notes ]
  end

  # Adds the text as a new line. Rules run again on every sync, so the text is
  # only added when no line of the notes already equals it; otherwise the notes
  # would grow every night.
  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    text = value.to_s.strip
    return 0 if text.blank?

    scope = transaction_scope.with_entry
    unless ignore_attribute_locks
      # Notes live on Entry, so check entries.locked_attributes
      scope = scope.where.not(
        Arel.sql("entries.locked_attributes ? 'notes'")
      )
    end

    count_modified_resources(scope) do |txn|
      notes = txn.entry.notes.to_s
      next false if notes.lines.any? { |line| line.strip == text }

      txn.entry.enrich_attribute(
        :notes,
        notes.blank? ? text : "#{notes.rstrip}\n#{text}",
        source: "rule",
        ignore_locks: ignore_attribute_locks
      )
    end
  end
end
