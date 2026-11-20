class Rule::ConditionFilter::TransactionAccount < Rule::ConditionFilter
  include Rule::AccountValue

  def type
    "select"
  end

  def apply(scope, operator, value)
    expression = build_sanitized_where_condition("entries.account_id", operator, value)
    scope.where(expression)
  end
end
