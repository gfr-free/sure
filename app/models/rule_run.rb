class RuleRun < ApplicationRecord
  belongs_to :rule

  validates :execution_type, inclusion: { in: %w[manual scheduled] }
  validates :status, inclusion: { in: %w[pending success failed] }
  validates :executed_at, presence: true
  validates :transactions_queued, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_processed, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_modified, numericality: { greater_than_or_equal_to: 0 }
  validates :pending_jobs_count, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(executed_at: :desc) }
  scope :for_rule, ->(rule) { where(rule: rule) }
  scope :successful, -> { where(status: "success") }
  scope :failed, -> { where(status: "failed") }
  scope :pending, -> { where(status: "pending") }

  def pending?
    status == "pending"
  end

  def success?
    status == "success"
  end

  def failed?
    status == "failed"
  end

  def transactions_blocked
    [ transactions_processed - transactions_modified, 0 ].max
  end

  # Thread-safe method to complete a job and update the run
  def complete_job!(modified_count: 0, job_id: nil)
    with_lock do
      # A redelivered job that already completed must not add its count again.
      self.transactions_modified += modified_count unless job_completed?(job_id)
      settle_job(job_id, "completed")

      # Preserve a previously recorded failure while still draining pending jobs.
      self.status = "success" if pending_jobs_count <= 0 && !failed?

      save!
    end
  end

  def fail_job!(error:, source:, transaction_ids: [], job_id: nil)
    should_log = false
    current_error_message = "#{error.class}: #{error.message}"

    with_lock do
      # A redelivery of a job that already completed has nothing left to fail.
      next if job_completed?(job_id)

      should_log = !failed?

      settle_job(job_id, "failed")
      self.status = "failed"
      existing_error_messages = error_message.to_s.split("\n").reject(&:blank?)
      self.error_message = (existing_error_messages + [ current_error_message ]).uniq.join("\n")

      save!
    end

    capture_failure_debug_log(error:, source:, transaction_ids:) if should_log
  end

  private
    # Sidekiq retries a failed job under the same job_id, so a job leaves the
    # pending count only on its first attempt that reports back.
    def settle_job(job_id, outcome)
      previous_outcome = settled_jobs[job_id] if job_id.present?

      self.pending_jobs_count = [ pending_jobs_count - 1, 0 ].max if previous_outcome.nil?
      self.settled_jobs = settled_jobs.merge(job_id => outcome) if job_id.present?
    end

    def job_completed?(job_id)
      job_id.present? && settled_jobs[job_id] == "completed"
    end

    def capture_failure_debug_log(error:, source:, transaction_ids:)
      DebugLogEntry.capture(
        category: "rule_run",
        level: "error",
        message: "Rule run failed: #{error.class}: #{error.message}",
        source: source,
        family: rule.family,
        metadata: {
          rule_run_id: id,
          rule_id: rule_id,
          rule_name: rule_name,
          execution_type: execution_type,
          error_class: error.class.name,
          error_message: error.message,
          transaction_count: transaction_ids.size,
          transaction_ids: transaction_ids,
          backtrace: Array(error.backtrace).first(10)
        }
      )
    end
end
