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
    # Twice a month needs a second day the form does not ask for.
    FREQUENCY_PRESETS = (FrequencyPreset::PRESETS - %w[semimonthly]) + [ FrequencyPreset::INTERVAL ]

    # What the form shows and submits under `repeat[...]`. Auto-posting is on
    # until the user turns it off.
    Settings = Struct.new(:enabled, :frequency_preset, :frequency_interval, :frequency_interval_unit, :auto_post,
                          keyword_init: true) do
      def self.from_params(params)
        submitted = params[:enabled] == "1"

        new(
          enabled: submitted,
          frequency_preset: params[:frequency_preset].presence || "monthly",
          frequency_interval: params[:frequency_interval].presence || 2,
          frequency_interval_unit: params[:frequency_interval_unit].presence || "monthly",
          auto_post: !submitted || params[:auto_post] == "1"
        )
      end
    end

    attr_reader :entry, :user, :settings, :series

    def initialize(entry:, user:, settings:)
      @entry = entry
      @user = user
      @settings = settings
    end

    # Returns true when the entry, the series and the first payment were all
    # saved. On false nothing was written, and the reason sits on the entry.
    def save
      return false unless repeatable_entry?

      saved = false

      Entry.transaction do
        raise ActiveRecord::Rollback unless entry.save && save_series

        allocate_first_date!
        saved = true
      end

      saved
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
           Allocator::OverAllocationError, Allocator::MissingRateError => e
      entry.errors.add(:base, I18n.t("recurring_transactions.from_new_entry.failed", error: e.message))
      false
    end

    private
      # Checked before anything is written, together with the entry's own
      # validations, so the form reports every problem at once.
      def repeatable_entry?
        valid = entry.valid?

        unless entry.account.manual?
          entry.errors.add(:base, I18n.t("recurring_transactions.from_new_entry.manual_account_required"))
          valid = false
        end

        # A series counts in its account's currency; a foreign-currency entry
        # would need an exchange rate for every future date.
        unless entry.currency == entry.account.currency
          entry.errors.add(:base, I18n.t("recurring_transactions.from_new_entry.account_currency_required"))
          valid = false
        end

        valid
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
        preset = settings.frequency_preset.to_s
        {
          name: entry.name,
          amount: entry.amount.abs,
          account_id: entry.account_id,
          first_due_on: entry.date.iso8601,
          is_income: entry.amount.negative?,
          frequency_preset: FREQUENCY_PRESETS.include?(preset) ? preset : "monthly",
          frequency_interval: settings.frequency_interval,
          frequency_interval_unit: settings.frequency_interval_unit,
          auto_post: settings.auto_post
        }
      end

      # Occurrences are normally generated after the series commits, which is
      # too late to attach the entry inside this transaction. Materializing
      # from the entry's date through today here also keeps a backdated
      # series whole: the later generation starts at the current cycle and
      # would leave the dates in between missing. It upserts, so the rows
      # made here are skipped.
      def allocate_first_date!
        OccurrenceGenerator.new(series).backfill!(from: entry.date, through: [ entry.date, Date.current ].max)
        occurrence = series.recurring_occurrences.find_by!(due_on: entry.date)

        Allocator.new(occurrence).allocate!(entry: entry, paid_on: entry.date)
      end
  end
end
