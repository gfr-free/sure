class RecurringTransaction
  # "Repeat" on the new-transaction form: saves the entry and, in the same
  # database transaction, declares a series that starts on the entry's date
  # and counts the entry as that first date's payment. From the next date on,
  # the series behaves like any declared bill, and posts by itself when
  # auto-posting is on.
  #
  # Manual accounts only: on a linked account the bank delivers the next
  # payments, and an auto-posted copy would count them twice. The series is
  # built through DeclaredBill, the same path as the add-bill form.
  class FromNewEntry
    attr_reader :entry, :user, :attrs, :series

    def initialize(entry:, user:, attrs:)
      @entry = entry
      @user = user
      @attrs = attrs
    end

    # Returns true when the entry, the series and the first payment were all
    # saved. On false nothing was written, and the reason sits on the entry.
    def save
      saved = false

      Entry.transaction do
        raise ActiveRecord::Rollback unless entry.save
        raise ActiveRecord::Rollback unless repeatable? && save_series

        allocate_first_date!
        saved = true
      end

      saved
    end

    private
      def repeatable?
        unless entry.account.manual?
          entry.errors.add(:base, I18n.t("recurring_transactions.from_new_entry.manual_account_required"))
          return false
        end

        # A series counts in its account's currency; a foreign-currency entry
        # would need an exchange rate for every future date.
        unless entry.currency == entry.account.currency
          entry.errors.add(:base, I18n.t("recurring_transactions.from_new_entry.account_currency_required"))
          return false
        end

        true
      end

      def save_series
        @series = DeclaredBill.new(family: entry.account.family, user: user, attrs: series_attrs).build

        if series.errors.none?
          # The entry's category and merchant were validated with the entry,
          # so the dates posted later look like the one entered now.
          series.category_id = entry.transaction.category_id
          series.merchant_id = entry.transaction.merchant_id
          return true if DeclaredBill.save(series)
        end

        series.errors.full_messages.each { |message| entry.errors.add(:base, message) }
        false
      end

      def series_attrs
        {
          name: entry.name,
          amount: entry.amount.abs,
          account_id: entry.account_id,
          first_due_on: entry.date.iso8601,
          is_income: entry.amount.negative?,
          frequency_preset: attrs[:frequency_preset],
          frequency_interval: attrs[:frequency_interval],
          frequency_interval_unit: attrs[:frequency_interval_unit],
          auto_post: attrs[:auto_post]
        }
      end

      # Occurrences are normally generated after the series commits, which is
      # too late to attach the entry inside this transaction. Materializing
      # the first date here is safe: the later generation upserts and skips
      # rows that already exist.
      def allocate_first_date!
        OccurrenceGenerator.new(series).backfill!(from: entry.date, through: entry.date)
        occurrence = series.recurring_occurrences.find_by!(due_on: entry.date)

        Allocator.new(occurrence).allocate!(entry: entry, paid_on: entry.date)
      end
  end
end
