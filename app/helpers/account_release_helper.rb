module AccountReleaseHelper
  # One line per release reminder for the e-mail digest: when the money is
  # released, or when a renewing deposit renews and until when it can be
  # cancelled.
  def account_release_line(reminder)
    scope = "account_availability_mailer.release_digest.lines"
    date = l(reminder.release_on, format: :long)

    case reminder.kind
    when "upcoming"
      t("#{scope}.upcoming", date: date, count: reminder.days_until)
    when "released"
      t("#{scope}.released", date: date)
    when "renewal"
      line = t("#{scope}.#{reminder.days_until.positive? ? "renewal" : "renewed"}", date: date)
      line += " #{t("#{scope}.cancel_by", date: l(reminder.cancel_by, format: :long))}" if reminder.notice_open?
      line += " #{t("#{scope}.grace_until", date: l(reminder.grace_until, format: :long))}" if reminder.grace_until
      line
    end
  end
end
