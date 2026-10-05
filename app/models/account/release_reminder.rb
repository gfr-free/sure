# Which locked accounts need a release reminder on a given day (decision E5).
#
# Three kinds:
# - upcoming: a locked account is released within the lead time
#   ("your term deposit is free on 15 Nov").
# - released: the release date has come ("the money is available now"). It
#   stays for RELEASED_WINDOW_DAYS so a missed daily run does not lose it.
# - renewal: a deposit that renews by itself is about to roll over. The
#   reminder starts the lead time before the last day to give notice and
#   lasts until that day, or until the grace period after renewing ends.
#
# Release is by calculation only (Account::Liquidity); nothing here changes
# the account. The insight generator and the e-mail job both ask this class,
# so the feed and the mail always agree on what is due.
class Account::ReleaseReminder
  KINDS = %w[upcoming released renewal].freeze

  DEFAULT_LEAD_DAYS = 14
  LEAD_DAYS_RANGE = (1..60)
  RELEASED_WINDOW_DAYS = 7

  attr_reader :account, :kind, :release_on, :cancel_by, :grace_until, :date

  class << self
    # Accounts that can produce a reminder at all; narrows the SQL before the
    # per-account date math runs in Ruby.
    def candidates(scope)
      scope.visible.assets.where(liquidity: "locked").where.not(available_on: nil)
    end

    def for(accounts, date:, lead_days:)
      accounts.filter_map { |account| build(account, date: date, lead_days: lead_days) }
              .sort_by { |reminder| [ reminder.release_on, reminder.account.name.to_s ] }
    end

    def build(account, date:, lead_days:)
      return nil unless account.asset? && account.liquidity == "locked" && account.available_on.present?

      if account.auto_renew?
        renewal(account, date: date, lead_days: lead_days)
      else
        release(account, date: date, lead_days: lead_days)
      end
    end

    private
      def release(account, date:, lead_days:)
        days = (account.available_on - date).to_i

        kind = if days.between?(1, lead_days)
          "upcoming"
        elsif days.between?(-(RELEASED_WINDOW_DAYS - 1), 0)
          "released"
        end

        kind && new(account: account, kind: kind, release_on: account.available_on, date: date)
      end

      # Searched from `date - grace_days` so a deposit that renewed yesterday
      # is still found while its grace period runs. When that renewal's window
      # has already closed (a notice period longer than the time left), the
      # one after it may already be open, so that one is checked too.
      def renewal(account, date:, lead_days:)
        return nil unless account.renewal_term_months.to_i.positive?

        renews_on = account.next_release_date(date - account.grace_days.to_i)
        2.times do
          reminder = renewal_on(account, renews_on, date: date, lead_days: lead_days)
          return reminder if reminder

          renews_on = account.next_release_date(renews_on + 1)
        end
        nil
      end

      def renewal_on(account, renews_on, date:, lead_days:)
        cancel_by = renews_on - account.notice_period_days.to_i
        grace_until = account.grace_period_end(renews_on)
        last_day = grace_until || cancel_by

        return nil unless date.between?(cancel_by - lead_days, last_day)

        new(account: account, kind: "renewal", release_on: renews_on, date: date,
            cancel_by: cancel_by, grace_until: grace_until)
      end
  end

  def initialize(account:, kind:, release_on:, date:, cancel_by: nil, grace_until: nil)
    @account = account
    @kind = kind
    @release_on = release_on
    @date = date
    @cancel_by = cancel_by
    @grace_until = grace_until
  end

  # Negative once the date has passed.
  def days_until
    (release_on - date).to_i
  end

  # Whether notice can still be given before the deposit renews; false once
  # only the grace period is left.
  def notice_open?
    kind == "renewal" && cancel_by >= date
  end

  def dedup_key
    "#{kind}:#{account.id}:#{release_on.iso8601}"
  end
end
