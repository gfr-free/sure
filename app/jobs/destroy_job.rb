class DestroyJob < ApplicationJob
  queue_as :low_priority
  # Inherits enqueue_after_transaction_commit = true from ApplicationJob. (This
  # previously read `= :never`, the removed Rails 7.2 symbol API; under 8.1 that
  # symbol is truthy, so it already deferred — the explicit line was dead and
  # misleading.) Deferring is correct here: destroy after the enclosing
  # transaction commits, never against an uncommitted/rolled-back record.

  def perform(model)
    model.destroy
  rescue => e
    report_failure(model, e)
    model.update!(scheduled_for_deletion: false) if model.respond_to?(:scheduled_for_deletion) # Let's the user try again by resetting the state
  end

  private
    # The rescue above keeps the job from retrying a destroy that would fail
    # the same way, so this is the only trace of why the record is still there.
    def report_failure(model, error)
      Rails.logger.error("DestroyJob failed for #{model.class.name} #{model.try(:id)}: #{error.class}: #{error.message}")
      Sentry.capture_exception(error) { |scope| scope.set_tags(record_type: model.class.name, record_id: model.try(:id)) } if defined?(Sentry)

      DebugLogEntry.capture(
        category: "background_jobs",
        level: "error",
        message: "Failed to delete #{model.class.name} #{model.try(:id)}: #{error.class}",
        source: self.class.name,
        **log_context(model),
        metadata: {
          record_type: model.class.name,
          record_id: model.try(:id),
          error_class: error.class.name,
          error_message: error.message.to_s.truncate(500)
        }
      )
    end

    def log_context(model)
      case model
      when Account then { account: model }
      when Family then { family: model }
      else
        family = model.try(:family)
        family.is_a?(Family) ? { family: family } : {}
      end
    end
end
