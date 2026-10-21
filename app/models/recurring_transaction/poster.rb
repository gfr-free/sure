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
      @today = today || family.today_in_timezone
    end

    # Returns how many occurrences were posted.
    def post_due!
      due = family.recurring_transactions.auto_posting.includes(:account, :destination_account).filter_map do |series|
        # Linking a bank, or changing the account's currency, changes nothing
        # on the series, so the switch can outlive what it needs.
        unless series.auto_post_available?
          stop_auto_posting!(series)
          next
        end
        next unless series.auto_post_accounts_active?

        # A date the user has to decide on waits in the Bills review queue.
        occurrences = series.auto_postable_occurrences(today).reject { |occurrence| series.auto_post_needs_decision?(occurrence) }
        [ series, occurrences ] if occurrences.any?
      rescue => e
        capture_failure(series, e)
        nil
      end
      return 0 if due.empty?
      return 0 unless match_existing_payments!

      posted = 0
      sync_from = {}

      due.each do |series, occurrences|
        occurrences.each do |occurrence|
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
    # `on_due_date` books the due date instead: the review queue's answer for
    # a date that appeared only after it was due, which the nightly run skips.
    #
    # Returns the posted entry, or nil when the date cannot be posted (any
    # allocation already recorded, not open, zero amount, or the series is not
    # postable).
    def post_now!(occurrence, on_due_date: false)
      series = occurrence.recurring_transaction
      return unless series.postable_now?

      date = on_due_date ? occurrence.effective_due_on : today

      # A key of its own: the nightly key may still sit on an entry the user
      # unlinked from this date, and reusing that entry would book nothing new.
      key = "#{idempotency_key(occurrence)}-now-#{SecureRandom.hex(6)}"
      entry = begin
        post_occurrence!(series, occurrence, date: date, key: key, repost: true)
      rescue Money::ConversionError => e
        # A transfer into an account in another currency, with no rate for that day.
        capture_failure(series, e)
        nil
      end
      return unless entry

      series.account.sync_later(window_start_date: date) unless series.transfer?
      entry
    end

    private
      # `repost` lets the user post a date again whose posted entry they
      # deleted; the nightly run never does.
      def post_occurrence!(series, occurrence, date: nil, key: idempotency_key(occurrence), repost: false, pending_review: false)
        RecurringOccurrence.transaction do
          occurrence.lock!
          # A pause, snooze or switch-off saved while the nightly run was under
          # way wins over what the run loaded before.
          unless repost
            next nil unless occurrence.effective_due_on <= today
            next nil unless family.recurring_transactions.auto_posting.exists?(series.id)
          end
          date ||= occurrence.effective_due_on
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

      # A payment the user already entered by hand claims its date first, so
      # it is not booked a second time. Families without a bank sync never run
      # the sync-triggered matcher otherwise. If this pass fails nothing posts
      # tonight; the next run catches up on the missed dates.
      def match_existing_payments!
        RecurringTransaction::Matcher.new(family).run!
        true
      rescue => e
        DebugLogEntry.capture(
          category: "recurring_auto_post",
          level: "error",
          message: "Family##{family.id}: matching before auto-posting failed: #{e.class} - #{e.message}",
          source: "recurring_transaction_poster",
          family: family
        )
        false
      end

      def idempotency_key(occurrence)
        "recurring-#{occurrence.id}"
      end

      # A bank feed now delivers this account's entries, so posting on top of
      # it would record every payment twice; or the account's currency no
      # longer matches the bill's, so the entry would book the wrong money.
      def stop_auto_posting!(series)
        series.stop_auto_posting_automatically!

        DebugLogEntry.capture(
          category: "recurring_auto_post",
          level: "warn",
          message: "RecurringTransaction##{series.id}: auto-posting stopped because the bill no longer meets its requirements",
          source: "recurring_transaction_poster",
          family: family,
          account: series.account,
          metadata: {
            recurring_transaction_id: series.id,
            destination_account_id: series.destination_account_id,
            accounts_manual: series.auto_post_accounts_manual?,
            currency: series.currency,
            account_currency: series.account&.currency
          }
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
  end
end
