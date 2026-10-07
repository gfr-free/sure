# Applies the "apply immediately" rules to transactions a person just created or
# changed. Rules above them that only run nightly still count (top rule wins,
# stop processing), exactly as in the nightly run.
class ApplyImmediateRulesJob < ApplicationJob
  queue_as :medium_priority

  retry_on Rule::Runner::LockBusy, wait: 30.seconds, attempts: 20

  def perform(family, transaction_ids:)
    rules = family.rules.applied_immediately
    return if rules.none?

    rule_runs = Rule::Runner.new(
      family,
      rules: rules,
      execution_type: "immediate",
      transaction_ids: transaction_ids
    ).run

    # Show the result in open pages without a manual reload.
    family.broadcast_refresh if rule_runs.any? { |rule_run| rule_run.pending? || rule_run.transactions_modified.to_i.positive? }
  end
end
