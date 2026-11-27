# Resolves what the precious metal picker posted to the coin's or bar's
# Security. The picker value is "product:<catalogue key>" (a coin by size, a
# bar by weight) or "custom:<spec id>" / "custom:new" (a family's own coin).
# Used by the trade form and by changing a holding's coin.
class BullionSpec::Choice
  PRODUCT_PREFIX = "product:".freeze
  CUSTOM_PREFIX = "custom:".freeze
  NEW_CUSTOM = "#{CUSTOM_PREFIX}new".freeze

  attr_reader :value

  def initialize(family:, value:, size: nil, weight: nil, weight_unit: nil,
                 custom_name: nil, custom_metal: nil, custom_fine_grams: nil,
                 custom_face_value: nil, custom_face_value_currency: nil)
    @family = family
    @value = value.to_s
    @size = size
    @weight = weight
    @weight_unit = weight_unit
    @custom_name = custom_name
    @custom_metal = custom_metal
    @custom_fine_grams = custom_fine_grams
    @custom_face_value = custom_face_value
    @custom_face_value_currency = custom_face_value_currency
  end

  # nil for an unknown product or another family's coin. Raises
  # ActiveRecord::RecordInvalid for an invalid new custom coin and
  # BullionCatalog::InvalidWeightError for an invalid bar weight.
  def security
    custom? ? custom_security : catalog_security
  rescue BullionCatalog::UnknownProductError
    nil
  end

  private
    attr_reader :family, :size, :weight, :weight_unit, :custom_name, :custom_metal, :custom_fine_grams,
                :custom_face_value, :custom_face_value_currency

    def custom?
      value.start_with?(CUSTOM_PREFIX)
    end

    def custom_security
      unless value == NEW_CUSTOM
        return family.bullion_specs.custom.find_by(id: value.delete_prefix(CUSTOM_PREFIX))&.security
      end

      BullionSpec.create_custom!(
        family: family,
        name: custom_name.to_s.strip,
        metal: custom_metal,
        fine_weight_grams: decimal_input(custom_fine_grams),
        face_value: decimal_input(custom_face_value),
        face_value_currency: custom_face_value.to_s.strip.presence && custom_face_value_currency
      ).security
    end

    # Number fields post a dot, but a typed "20,5" must not become 20 or 205.
    def decimal_input(value)
      value.to_s.strip.tr(",", ".").presence
    end

    def catalog_security
      product = BullionCatalog.find(value.delete_prefix(PRODUCT_PREFIX))
      return nil unless product

      if product.bar?
        BullionCatalog.bar_security_for(product.key, weight, weight_unit)
      else
        BullionCatalog.security_for(product.key, size)
      end
    end
end
