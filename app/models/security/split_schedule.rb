# The splits that apply to one family's securities, answering "how many of
# today's shares is one share held on this date?".
#
# Holdings are calculated on today's share basis: a share bought before a 1:4
# split counts as four, at a quarter of its price. That keeps quantities in
# step with split-adjusted price history and leaves value and cost unchanged.
class Security::SplitSchedule
  # How far a broker's zero-price split trade may sit from the split's date and
  # still be recognised as that split (brokers book on ex-date or pay date).
  BROKER_SPLIT_WINDOW = 5.days

  def self.load(security_ids:, family_id:)
    return new({}) if security_ids.blank?

    splits = Security::Split
      .where(security_id: security_ids, family_id: [ nil, family_id ])
      .chronological
      .to_a

    new(splits.group_by(&:security_id))
  end

  def initialize(splits_by_security_id)
    # A family's own entry replaces a provider split near the same day, so the
    # user can correct a ratio the provider got wrong, and the same split
    # recorded on ex-date by one and pay date by the other is not counted twice.
    @splits_by_security_id = splits_by_security_id.transform_values do |splits|
      own, provided = splits.partition(&:family_id)
      provided = provided.reject { |split| own.any? { |mine| near?(mine.date, split.date) } }
      (own + provided).sort_by(&:date)
    end
  end

  def empty?
    @splits_by_security_id.empty?
  end

  def splits_for?(security_id)
    @splits_by_security_id[security_id].present?
  end

  # Product of every split after `date`: one share held on `date` is this many
  # shares today. Splits take effect on their own date, so a trade on the split
  # date is already on the new basis.
  def factor_after(security_id, date)
    (@splits_by_security_id[security_id] || []).reduce(BigDecimal("1")) do |factor, split|
      split.date > date ? factor * split.factor : factor
    end
  end

  # Brokers (SnapTrade, Plaid, Indexa) book a split as an "Other" trade for
  # the extra shares, and users without split support entered it as a
  # zero-price buy. Where a split record covers such a trade, counting it as
  # well would add the new shares twice, so the calculators skip it. The trade
  # itself stays in the account untouched.
  def covers_broker_split_trade?(trade, date)
    return false if trade.qty.blank? || trade.qty.to_d.zero?
    return false unless split_like_trade?(trade)

    (@splits_by_security_id[trade.security_id] || []).any? do |split|
      near?(split.date, date) && (split.factor > 1) == trade.qty.to_d.positive?
    end
  end

  private
    def split_like_trade?(trade)
      return true if trade.investment_activity_label == "Other"
      return false if trade.internal_movement?

      trade.price.present? && trade.price.to_d.zero? && trade.investment_activity_label.in?([ nil, "Buy", "Sell" ])
    end

    def near?(date, other_date)
      (date - other_date).abs <= BROKER_SPLIT_WINDOW.in_days
    end
end
