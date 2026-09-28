# Kind-specific fields, stored in the `details` jsonb column: an insurance's
# line and sum insured, a phone plan's tariff, an energy contract's price
# guarantee. Only the keys of the contract's current kind are kept, each typed
# and validated here.
module Contract::Detailable
  extend ActiveSupport::Concern

  INSURANCE_LINES = %w[
    liability household building accident disability term_life whole_life
    car legal health_supplementary care pet travel other
  ].freeze

  # Lines whose premiums commonly count as "sonstige Vorsorgeaufwendungen"
  # in a German tax return (§10 Abs. 1 Nr. 3a EStG). For car insurance only
  # the liability share counts. Shown as "possibly deductible": the tax office
  # and the caps decide, not Sure.
  TAX_RELEVANT_INSURANCE_LINES = %w[liability accident disability term_life health_supplementary care car].freeze

  DETAIL_FIELDS = {
    "insurance" => {
      "insurance_line" => :insurance_line,
      "sum_insured" => :decimal,
      "deductible" => :decimal,
      "insured_persons" => :text,
      "beneficiaries" => :text
    },
    "mobile" => {
      "tariff" => :string,
      "phone_number" => :string,
      "data_volume_gb" => :decimal,
      "device_paid_off_on" => :date
    },
    "internet" => {
      "tariff" => :string,
      "bandwidth_mbit" => :decimal
    },
    "energy" => {
      "tariff" => :string,
      "advance_payment" => :decimal,
      "price_guarantee_until" => :date,
      "meter_number" => :string
    },
    "rent" => {
      "landlord" => :string,
      "deposit" => :decimal
    },
    "streaming" => { "plan" => :string },
    "software" => { "plan" => :string },
    "fitness" => { "plan" => :string },
    "membership" => { "plan" => :string },
    "other" => {}
  }.freeze

  MAX_TEXT_LENGTH = 1000
  MAX_STRING_LENGTH = 255

  included do
    before_validation :normalize_details
    validate :details_are_valid
  end

  class_methods do
    def detail_fields_for(kind)
      DETAIL_FIELDS.fetch(kind.to_s, {})
    end

    def insurance_line_options
      INSURANCE_LINES.map { |line| [ I18n.t("contracts.insurance_lines.#{line}"), line ] }
    end
  end

  def detail_fields
    self.class.detail_fields_for(kind)
  end

  def detail(key)
    details.to_h[key.to_s]
  end

  # Typed read: decimals as BigDecimal, dates as Date.
  def typed_detail(key)
    value = detail(key)
    return if value.blank?

    case detail_fields[key.to_s]
    when :decimal then BigDecimal(value.to_s)
    when :date then Date.iso8601(value.to_s)
    else value
    end
  rescue ArgumentError, Date::Error
    nil
  end

  def insurance_line
    detail("insurance_line") if insurance?
  end

  def possibly_tax_deductible?
    insurance? && insurance_line.in?(TAX_RELEVANT_INSURANCE_LINES)
  end

  private

    # Drops keys that do not belong to the kind (a contract switched from
    # insurance to mobile loses the sum insured) and blanks.
    def normalize_details
      allowed = detail_fields
      self.details = details.to_h.each_with_object({}) do |(key, value), clean|
        next unless allowed.key?(key.to_s)

        stripped = value.is_a?(String) ? value.strip : value
        clean[key.to_s] = stripped unless stripped.blank?
      end
    end

    def details_are_valid
      details.to_h.each do |key, value|
        valid = case detail_fields[key]
        when :decimal
          (BigDecimal(value.to_s) >= 0 rescue false)
        when :date
          (Date.iso8601(value.to_s).present? rescue false)
        when :insurance_line
          INSURANCE_LINES.include?(value)
        when :text
          value.to_s.length <= MAX_TEXT_LENGTH
        else
          value.to_s.length <= MAX_STRING_LENGTH
        end

        errors.add(:details, :invalid_field, field: I18n.t("contracts.details.fields.#{key}")) unless valid
      end
    end
end
