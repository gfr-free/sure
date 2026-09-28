# Emails a contract's owner ahead of its notice deadline: 30, 7 and 1 day(s)
# before. Each stage goes out once per deadline, recorded on the contract, so
# a missed nightly run catches up with the most urgent stage instead of
# sending all of them.
class ContractNoticeRemindersJob < ApplicationJob
  queue_as :scheduled

  STAGES = [ 30, 7, 1 ].freeze

  def perform
    Contract.where(status: "active", email_reminders: true)
            .joins(:family).where(families: { recurring_transactions_disabled: false })
            .includes(:owner, :family)
            .find_each do |contract|
      remind(contract)
    rescue => e
      DebugLogEntry.capture(
        category: "contracts",
        level: "error",
        message: "Contract reminder failed: #{e.class}: #{e.message}",
        source: "ContractNoticeRemindersJob",
        family: contract.family,
        metadata: { contract_id: contract.id }
      )
    end
  end

  private
    def remind(contract)
      owner = contract.owner
      return unless owner.active? && owner.preview_features_enabled?

      today = contract.family.timezone.present? ? Time.current.in_time_zone(contract.family.timezone).to_date : Date.current
      schedule = contract.notice_schedule(today: today)
      deadline = schedule.notice_deadline
      return if deadline.nil?

      days_left = (deadline - today).to_i
      due = STAGES.select { |stage| days_left <= stage }
      return if due.empty?

      sent = Array(contract.notice_reminders_sent[deadline.iso8601])
      return if (due - sent).empty?

      ContractMailer.notice_reminder(contract: contract, deadline: deadline, term_ends_on: schedule.term_ends_on || deadline).deliver_later
      # Only this deadline's history is kept; older ones have passed.
      contract.update_columns(notice_reminders_sent: { deadline.iso8601 => (sent | due).sort.reverse }, updated_at: Time.current)
    end
end
