class Rule::ActionExecutor::SetTransactionMerchant < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.assignable_merchants_for(Current.user).alphabetically.pluck(:name, :id)
  end

  def claimed_attributes
    [ :merchant_id ]
  end

  def actionable?(value)
    assignable_merchant(value).present?
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    merchant = assignable_merchant(value)
    return 0 unless merchant

    scope = transaction_scope
    unless ignore_attribute_locks
      scope = scope.enrichable(:merchant_id)
    end

    count_modified_resources(scope) do |txn|
      # enrich_attribute returns true if the transaction was actually modified, false otherwise
      txn.enrich_attribute(
        :merchant_id,
        merchant.id,
        source: "rule",
        ignore_locks: ignore_attribute_locks
      )
    end
  end

  private
    # Rules run in the background without a user, so this checks the whole
    # family: one of its own merchants, or a provider merchant that is still on
    # one of its transactions.
    def assignable_merchant(value)
      return if value.blank?

      family.merchants.find_by(id: value) ||
        (ProviderMerchant.find_by(id: value) if family.transactions.exists?(merchant_id: value))
    end
end
