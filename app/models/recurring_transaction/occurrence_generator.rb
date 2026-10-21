class RecurringTransaction
  # Materializes Schedule output into recurring_occurrences rows. An idempotent
  # upsert keyed on (series, original_due_on), so re-running only adds missing
  # rows and never duplicates or touches existing ones.
  #
  # Only scheduled, allocation-free, not-yet-due rows are ever deleted. Anything
  # closed or carrying a payment is immutable history.
  class OccurrenceGenerator
    HORIZON_DAYS = 90

    attr_reader :series

    def initialize(series)
      @series = series
    end

    # From the start of the current cycle, so a recently-due unpaid occurrence
    # exists and not just future ones, through a horizon always extended far
    # enough to include the next occurrence even on annual cadences.
    def generate!(through: nil)
      return 0 unless series.active?

      schedule = series.schedule
      from = schedule.cycle_for(Date.current)&.begin || Date.current

      # A declared bill's anchor is its first obligation, so the cycle lookback
      # must not fabricate a previous-cycle debt. Auto-detected series keep the
      # cycle start, since their history predates the row.
      from = [ from, series.anchor_date ].compact.max if series.manual?

      through ||= default_horizon(schedule)

      upsert_window(from, through)
    end

    # After a schedule edit: drop the re-generatable future and rebuild it under
    # the new rules. Rows with payments or closed state are kept as they were.
    def regenerate_future!(through: nil)
      regenerable = series.recurring_occurrences
                          .open_status
                          .where("due_on >= ?", Date.current)
                          .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
      # A date that already posted (its entry since deleted) must never post
      # again, so its row is never deleted and rebuilt without the stamp.
      posted = regenerable.where.not(auto_posted_at: nil).to_a
      regenerable.where(auto_posted_at: nil).delete_all

      created = generate!(through: through)
      keep_posted_dates!(posted)
      created
    end

    # Materializes a past window (catch-up/backfill). The caller decides what
    # happens to uncovered past occurrences; this only creates rows.
    def backfill!(from:, through: Date.current)
      return 0 unless series.active?

      upsert_window(from, through)
    end

    private
      # A posted date the new schedule still has follows its weekend-adjusted
      # day; one it dropped is closed as skipped rather than left as an extra
      # obligation. A paused series keeps them as they are until it resumes.
      def keep_posted_dates!(posted)
        return if posted.empty? || !series.active?

        dates = posted.flat_map { |occurrence| [ occurrence.original_due_on, occurrence.due_on ] }
        # Weekend adjustment moves a date by a few days at most.
        pairs = series.schedule.occurrence_pairs_between(dates.min - 7, dates.max + 7).index_by(&:original_due_on)

        posted.each do |occurrence|
          if (pair = pairs[occurrence.original_due_on])
            occurrence.update!(due_on: pair.due_on) if occurrence.due_on != pair.due_on
          else
            # A new raw date landing on the same day is the same payment.
            series.recurring_occurrences.where(due_on: occurrence.due_on, auto_posted_at: nil)
                  .update_all(auto_posted_at: occurrence.auto_posted_at)
            occurrence.skip!(source: "auto")
          end
        end
      end

      def default_horizon(schedule)
        horizon = Date.current + HORIZON_DAYS
        next_due = schedule.first_occurrence_after(Date.current)

        # A finite plan materializes whole: an installment run is bounded by
        # definition, and seeing all N payments (and the end) is the point.
        if series.ends_after_count? && series.end_after_count.present?
          cycle_days = (365.25 / schedule.occurrences_per_year).ceil
          plan_end = (series.anchor_date || Date.current) + cycle_days * (series.end_after_count + 1)
          return [ horizon, next_due, plan_end ].compact.max
        end

        [ horizon, next_due ].compact.max
      end

      def upsert_window(from, through)
        pairs = series.schedule.occurrence_pairs_between(from, through)
        return 0 if pairs.empty?

        now = Time.current
        rows = pairs.map do |pair|
          {
            recurring_transaction_id: series.id,
            family_id: series.family_id,
            original_due_on: pair.original_due_on,
            due_on: pair.due_on,
            currency: series.currency,
            status: "scheduled",
            created_at: now,
            updated_at: now
          }
        end

        result = RecurringOccurrence.insert_all(rows, unique_by: "idx_recurring_occurrences_identity")
        result.rows.size
      end
  end
end
