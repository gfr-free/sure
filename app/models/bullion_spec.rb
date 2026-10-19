# Fine metal content of a bullion coin or bar, attached to the Security that
# holds its trades. Catalogue entries (family_id nil) are shared by everyone and
# come from config/bullion_products.yml; custom entries belong to one family.
class BullionSpec < ApplicationRecord
  TROY_OUNCE_GRAMS = BigDecimal("31.1034768")
  # 100 kg; the column keeps eight digits before the decimal point.
  MAX_FINE_WEIGHT_GRAMS = BigDecimal("100000")
  METALS = %w[XAU XAG XPT XPD].freeze
  TICKER_PREFIX = "BULLION-".freeze
  CUSTOM_TICKER_PREFIX = "#{TICKER_PREFIX}CUSTOM-".freeze

  belongs_to :security
  belongs_to :family, optional: true

  delegate :name, to: :security, allow_nil: true

  validates :metal, inclusion: { in: METALS }
  # Stored with four decimals; rounding first keeps a weight that would round
  # to zero, or overflow the column, a validation error instead of a crash.
  before_validation { self.fine_weight_grams = fine_weight_grams.round(4) if fine_weight_grams.is_a?(Numeric) }
  validates :fine_weight_grams, numericality: { greater_than: 0, less_than_or_equal_to: MAX_FINE_WEIGHT_GRAMS }
  validates :catalog_key, :size_key, presence: true, unless: :custom?
  validates :catalog_key, :size_key, absence: true, if: :custom?
  validates :security_id, uniqueness: true
  validate :custom_security_named, if: :custom?

  before_destroy :ensure_custom_security_unused, if: :custom?
  after_destroy :destroy_custom_security, if: :custom?

  scope :catalog, -> { where(family_id: nil) }
  scope :custom, -> { where.not(family_id: nil) }

  # Offline: the price is derived from the metal price, never fetched for the
  # piece itself.
  def self.security_attributes
    {
      offline: true,
      asset_class: "commodity",
      asset_sub_class: "precious_metal",
      classification_source: "default"
    }
  end

  def self.create_custom!(family:, name:, metal:, fine_weight_grams:)
    security = Security.new(ticker: "#{CUSTOM_TICKER_PREFIX}#{SecureRandom.hex(6).upcase}", name: name, **security_attributes)
    spec = new(security: security, family: family, metal: metal, fine_weight_grams: fine_weight_grams)
    spec.validate!

    transaction do
      security.save!
      spec.save!
    end
    spec
  end

  def custom?
    family_id.present?
  end

  def fine_troy_ounces
    fine_weight_grams / TROY_OUNCE_GRAMS
  end

  private
    def custom_security_named
      errors.add(:name, :blank) if name.blank?
    end

    # A coin that still has trades or holdings stays; removing it would orphan
    # (or, through foreign keys, block) that history.
    def ensure_custom_security_unused
      in_use = Trade.where(security_id: security_id).exists? ||
        Holding.where(security_id: security_id).or(Holding.where(provider_security_id: security_id)).exists?
      return unless in_use

      errors.add(:base, :in_use)
      throw :abort
    end

    def destroy_custom_security
      security.destroy!
    end
end
