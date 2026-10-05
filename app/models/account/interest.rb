# Interest terms on an account (liquidity concept, decision E18: the slim
# first step of the interest sub-concept).
#
# - A rate history in `account_interest_rates`: the credit rate paid on a
#   positive balance and, on bank accounts, a debit rate charged on an
#   overdraft. Planned changes (a teaser rate that ends) are future entries.
# - `interest_payout_frequency`: how often the interest is paid into the
#   account itself. Without one, the subtype's usual rhythm applies.
#
# What the terms produce (accrued interest, the next payout, the value at
# maturity) lives in Account::InterestProjection; the arithmetic in
# InterestMath. Loans keep their own rate model and amortisation schedule;
# `interest_rate_on` only reads it, and a credit card's debit rate is its APR.
#
# The form writes the history through virtual attributes, so the account form
# stays one form: the current rate, the overdraft rate and one planned change.
module Account::Interest
  extend ActiveSupport::Concern

  PAYOUT_FREQUENCIES = %w[daily monthly quarterly semiannual annual at_maturity].freeze
  CREDIT_TYPES = %w[Depository OtherAsset].freeze
  DEBIT_TYPES = %w[Depository].freeze

  included do
    has_many :interest_rates, class_name: "Account::InterestRate", dependent: :destroy

    validates :interest_payout_frequency, inclusion: { in: PAYOUT_FREQUENCIES }, allow_nil: true
    validate :interest_inputs_must_be_valid

    before_validation :normalize_interest_payout_frequency
    after_save :apply_interest_inputs
  end

  attr_reader :interest_rate_input, :overdraft_rate_input, :planned_interest_rate, :planned_interest_rate_on

  def interest_rate_input=(value)
    @interest_rate_input = value.to_s.strip
  end

  def overdraft_rate_input=(value)
    @overdraft_rate_input = value.to_s.strip
  end

  def planned_interest_rate=(value)
    @planned_interest_rate = value.to_s.strip
  end

  def planned_interest_rate_on=(value)
    @planned_interest_rate_on = value.to_s.strip
  end

  def interest_capable?
    accountable_type.in?(CREDIT_TYPES)
  end

  def overdraft_interest_capable?
    accountable_type.in?(DEBIT_TYPES)
  end

  # Whether the account has interest the projection can work with.
  def interest_terms?
    interest_capable? && sorted_interest_rates.any?
  end

  # The nominal rate in percent per year on `date`, nil when none applies.
  def interest_rate_on(date, applies_to: "credit")
    case accountable_type
    when "Loan"
      applies_to == "debit" ? Loan::RateResolver.for(accountable).accrual_rate_for(date) : nil
    when "CreditCard"
      applies_to == "debit" ? accountable.apr : nil
    else
      rate_entry_on(date, applies_to)&.rate
    end
  end

  def rate_entry_on(date, applies_to)
    sorted_interest_rates.select { |entry| entry.applies_to == applies_to && entry.effective_from <= date }.last
  end

  # Entries that start after `date`: planned changes such as the end of a
  # teaser rate.
  def upcoming_interest_rates(date = liquidity_today)
    sorted_interest_rates.select { |entry| entry.effective_from > date }
  end

  # The payout rhythm in effect: the user's choice, else the subtype's usual
  # one. Term deposits pay at maturity, building savings once a year.
  def effective_interest_payout_frequency
    interest_payout_frequency.presence || default_interest_payout_frequency
  end

  def default_interest_payout_frequency
    return "annual" unless accountable_type == "Depository"

    case subtype
    when "cd" then "at_maturity"
    when "building_savings" then "annual"
    else "monthly"
    end
  end

  def interest_projection(as_of: liquidity_today)
    Account::InterestProjection.new(self, as_of: as_of)
  end

  # Form values: what the rate fields show before the user types.
  def interest_rate_for_form
    interest_rate_input || rate_entry_on(liquidity_today, "credit")&.rate&.to_s
  end

  def overdraft_rate_for_form
    overdraft_rate_input || rate_entry_on(liquidity_today, "debit")&.rate&.to_s
  end

  private
    def sorted_interest_rates
      interest_rates.sort_by(&:effective_from)
    end

    def normalize_interest_payout_frequency
      self.interest_payout_frequency = interest_payout_frequency.presence
      self.interest_payout_frequency = nil unless interest_capable?
    end

    def parsed_rate(value)
      return nil if value.blank?

      BigDecimal(value.to_s.tr(",", "."))
    rescue ArgumentError
      :invalid
    end

    def interest_inputs_must_be_valid
      [ [ :interest_rate_input, interest_rate_input ], [ :overdraft_rate_input, overdraft_rate_input ],
        [ :planned_interest_rate, planned_interest_rate ] ].each do |attribute, value|
        rate = parsed_rate(value)
        next if rate.nil?

        if rate == :invalid || rate < Account::InterestRate::MIN_RATE || rate > Account::InterestRate::MAX_RATE
          errors.add(attribute, :invalid)
        end
      end

      validate_planned_rate_change
    end

    def validate_planned_rate_change
      return if planned_interest_rate.blank? && planned_interest_rate_on.blank?

      if planned_interest_rate.blank?
        errors.add(:planned_interest_rate, :blank)
      elsif planned_interest_rate_on.blank?
        errors.add(:planned_interest_rate_on, :blank)
      elsif (date = parsed_planned_date).nil? || date <= liquidity_today
        errors.add(:planned_interest_rate_on, I18n.t("accounts.interest.errors.planned_in_future"))
      end
    end

    def parsed_planned_date
      Date.iso8601(planned_interest_rate_on)
    rescue Date::Error
      nil
    end

    def apply_interest_inputs
      return unless interest_capable?

      apply_current_rate("credit", interest_rate_input) unless interest_rate_input.nil?
      apply_current_rate("debit", overdraft_rate_input) if overdraft_interest_capable? && !overdraft_rate_input.nil?

      if planned_interest_rate.present? && planned_interest_rate_on.present?
        upsert_rate("credit", parsed_planned_date, parsed_rate(planned_interest_rate))
      end

      @interest_rate_input = @overdraft_rate_input = @planned_interest_rate = @planned_interest_rate_on = nil
      interest_rates.reset
    end

    # The rate field sets the rate in force today. Clearing a rate the field
    # showed removes it, planned changes included; a field that was empty
    # because only a planned rate exists leaves that plan alone. The first
    # rate an account gets applies from its start, so the interest accrued so
    # far can be worked out.
    def apply_current_rate(applies_to, input)
      rates = interest_rates.where(applies_to: applies_to)
      today = liquidity_today
      value = parsed_rate(input)
      current = rates.where(effective_from: ..today).order(:effective_from).last

      if value.nil?
        rates.delete_all if current
        return
      end

      return if current&.rate == value

      upsert_rate(applies_to, current ? today : [ start_date, today ].min, value)
    end

    def upsert_rate(applies_to, date, value)
      entry = interest_rates.find_or_initialize_by(applies_to: applies_to, effective_from: date)
      entry.update!(rate: value, source: "manual")
    end
end
