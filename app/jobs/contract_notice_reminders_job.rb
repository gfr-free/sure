# Emails a contract's owner ahead of its notice deadline, and ahead of the end
# of an energy contract's price guarantee: 30, 7 and 1 day(s) before. Each
# stage goes out once per date, recorded on the contract, so a missed nightly
# run catches up with the most urgent stage instead of sending all of them.
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

      today = contract.family.current_date
      sent = contract.notice_reminders_sent.to_h
      # Only the current deadline's and price guarantee's history is kept;
      # older ones have passed.
      kept = {}

      schedule = contract.notice_schedule(today: today)
      if (deadline = schedule.notice_deadline)
        kept[deadline.iso8601] = remind_once(sent, deadline.iso8601, deadline, today) do
          ContractMailer.notice_reminder(contract: contract, deadline: deadline, term_ends_on: schedule.term_ends_on || deadline).deliver_later
        end
      end

      guarantee_until = contract.price_guarantee_until
      if guarantee_until && contract.open?(on: today)
        key = "price_guarantee:#{guarantee_until.iso8601}"
        kept[key] = remind_once(sent, key, guarantee_until, today) do
          ContractMailer.price_guarantee_reminder(contract: contract, guarantee_until: guarantee_until).deliver_later
        end
      end

      kept.compact!
      contract.update_columns(notice_reminders_sent: kept, updated_at: Time.current) unless kept == sent
    end

    # Sends once per date for the stages that are due, catching up with the
    # most urgent one after a missed run. Returns the stages sent for the date
    # so far, or nil before the first stage or once the date has passed.
    def remind_once(sent, key, date, today)
      days_left = (date - today).to_i
      return if days_left.negative?

      due = STAGES.select { |stage| days_left <= stage }
      return if due.empty?

      already = Array(sent[key])
      yield unless (due - already).empty?
      (already | due).sort.reverse
    end
end
