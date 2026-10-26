# frozen_string_literal: true

class AddSettledJobsToRuleRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_runs, :settled_jobs, :jsonb, default: {}, null: false
  end
end
