class RecurringTransaction
  # Posts the entry for every due date of an auto-posting series, so a manual
  # account records rent, salary or a savings transfer without the user typing
  # it in. Runs nightly under the family's pipeline lock.
  #
  # Each occurrence posts at most once: `auto_posted_at` is stamped in the same
  # database transaction as the entry, and the entry carries an idempotency key
  # derived from the occurrence. Deleting the posted entry reopens the
  # occurrence (see Entry#release_auto_posted_allocations) without re-posting.
  #
  # Nightly posts are provisional: they count as paid, but wait for the user
  # to confirm them or discard them (which skips the date), the same way an
  # auto-matched transfer is reviewed.
  class Poster
    attr_reader :family, :today

    def initialize(family, today: nil)
      @family = family
      @today = today || family_today
    end

    # Returns how many occurrences were posted.
    def post_due!
      posted = 0
      sync_from = {}

      family.recurring_transactions.auto_posting.includes(:account, :destination_account).find_each do |series|
        unless series.auto_post_accounts_manual?
          stop_auto_posting!(series)
          next
        end
        next unless series.auto_post_accounts_active?

        series.auto_postable_occurrences(today).each do |occurrence|
          next unless post_occurrence!(series, occurrence, pending_review: true)

          posted += 1
          unless series.transfer?
            sync_from[series.account] = [ sync_from[series.account], occurrence.effective_due_on ].compact.min
          end
        end
      rescue => e
        capture_failure(series, e)
      end

      # One balance recalculation per account instead of one per entry.
      # Transfer::Creator already schedules its own syncs.
      sync_from.each { |account, date| account.sync_later(window_start_date: date) }

      posted
    end

    # "Post now": the user paid an open date early (or late) and records it
    # with one click instead of typing it in. Same entry and allocation as the
    # nightly run, but dated today, not on the due date, and independent of the
    # auto-post switch. Stamps `auto_posted_at` like a nightly post, so the
    # job never posts the date again, even after the entry is deleted.
    #
    # Returns the posted entry, or nil when the date cannot be posted (any
    # allocation already recorded, not open, zero amount, or the series is not
    # postable).
    def post_now!(occurrence)
      series = occurrence.recurring_transaction
      return unless series.postable_now?

      # A key of its own: the nightly key may still sit on an entry the user
      # unlinked from this date, and reusing that entry would book nothing new.
      key = "#{idempotency_key(occurrence)}-now-#{SecureRandom.hex(6)}"
      entry = post_occurrence!(series, occurrence, date: today, key: key, repost: true)
      return unless entry

      series.account.sync_later(window_start_date: today) unless series.transfer?
      entry
    end

    private
      # `repost` lets the user post a date again whose posted entry they
      # deleted; the nightly run never does.
      def post_occurrence!(series, occurrence, date: occurrence.effective_due_on, key: idempotency_key(occurrence), repost: false, pending_review: false)
        RecurringOccurrence.transaction do
          occurrence.lock!
          # Re-checked under the lock. Any existing allocation means the user
          # (or the matcher) already recorded a payment or a candidate for this
          # date, and posting another entry would count it twice.
          next nil unless occurrence.scheduled? && (repost || occurrence.auto_posted_at.nil?)
          next nil if occurrence.allocations.exists?
          # A date the user set to zero has nothing to post.
          next nil unless occurrence.resolved_expected_amount.positive?

          entry = series.transfer? ? post_transfer!(series, occurrence, date, key) : post_entry!(series, occurrence, date, key)
          RecurringTransaction::Allocator.new(occurrence).allocate_posted!(entry: entry, pending_review: pending_review)
          occurrence.update!(auto_posted_at: Time.current)
          entry
        end
      end

      def post_entry!(series, occurrence, date, key)
        existing = series.account.entries.find_by(idempotency_key: key)
        return existing if existing

        amount = occurrence.resolved_expected_amount
        entry = series.account.entries.create!(
          date: date,
          name: series.display_name,
          amount: series.amount.negative? ? -amount : amount,
          currency: series.currency,
          notes: series.notes,
          user_modified: true,
          idempotency_key: key,
          entryable: Transaction.new(category_id: series.category_id, merchant_id: series.merchant_id)
        )
        # Rules may fill empty fields later, but never overwrite what the
        # series set.
        entry.lock_saved_attributes!
        entry
      end

      def post_transfer!(series, occurrence, date, key)
        transfer = Transfer::Creator.new(
          family: family,
          source_account_id: series.account_id,
          destination_account_id: series.destination_account_id,
          date: date,
          amount: occurrence.resolved_expected_amount,
          idempotency_key: key
        ).create

        transfer.outflow_transaction.entry
      end

      def idempotency_key(occurrence)
        "recurring-#{occurrence.id}"
      end

      # A bank feed now delivers this account's entries, so posting on top of
      # it would record every payment twice.
      def stop_auto_posting!(series)
        series.update!(auto_post: false)

        DebugLogEntry.capture(
          category: "recurring_auto_post",
          level: "warn",
          message: "RecurringTransaction##{series.id}: auto-posting stopped because an account is no longer manual",
          source: "recurring_transaction_poster",
          family: family,
          account: series.account,
          metadata: { recurring_transaction_id: series.id, destination_account_id: series.destination_account_id }
        )
      end

      def capture_failure(series, error)
        DebugLogEntry.capture(
          category: "recurring_auto_post",
          level: "error",
          message: "RecurringTransaction##{series.id}: auto-posting failed: #{error.class} - #{error.message}",
          source: "recurring_transaction_poster",
          family: family,
          account: series.account,
          metadata: { recurring_transaction_id: series.id }
        )
      end

      # The family's calendar day, not the server's: a series due on the 1st
      # posts on the 1st where the family lives.
      def family_today
        zone = ActiveSupport::TimeZone[family.timezone.to_s] || Time.zone
        Time.current.in_time_zone(zone).to_date
      end
  end
end
