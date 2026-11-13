module TradesHelper
  BULLION_ACCOUNT_SUBTYPES = %w[precious_metals gold].freeze

  # The trade form reloads itself (query params) when a choice changes the
  # fields it shows, and re-renders from the submitted model params on errors.
  def trade_form_param(key)
    params[key].presence || params.dig(:model, key).presence
  end

  # A posted currency code for re-rendering the form, nil when it is unknown.
  def trade_form_currency_param(key)
    code = trade_form_param(key)
    Money::Currency.new(code).iso_code if code
  rescue Money::Currency::UnknownCurrencyError
    nil
  end

  # A posted number for re-rendering the form, nil when it is not one.
  def trade_form_decimal_param(key)
    value = trade_form_param(key)
    BigDecimal(value.to_s.strip.tr(",", ".")) if value
  rescue ArgumentError
    nil
  end

  # The form offers two kinds: a security, or precious metal (catalogue coins,
  # bars and the family's own coins in one list).
  FORM_HOLDING_KINDS = %w[security bullion].freeze

  def trade_holding_kind(account)
    kind = trade_form_param(:holding_kind)
    return "bullion" if kind == "custom_bullion"
    return kind if FORM_HOLDING_KINDS.include?(kind)

    BULLION_ACCOUNT_SUBTYPES.include?(account&.subtype) ? "bullion" : "security"
  end

  def trade_holding_kind_options
    FORM_HOLDING_KINDS.map { |kind| [ t("trades.form.holding_kinds.#{kind}"), kind ] }
  end

  # The posted choice, else the given default (e.g. a holding's current
  # coin), else the first catalogue product.
  def trade_bullion_choice(family, default = nil)
    valid = bullion_choice_options(family).flat_map(&:last).map(&:last)
    choice = [ trade_form_param(:bullion_choice), default ].find { |option| valid.include?(option) }
    return choice if choice

    valid.find { |option| option.start_with?(BullionSpec::Choice::PRODUCT_PREFIX) }
  end

  # The catalogue product behind a "product:<key>" choice, nil for custom coins.
  def trade_bullion_choice_product(choice)
    return unless choice.to_s.start_with?(BullionSpec::Choice::PRODUCT_PREFIX)

    BullionCatalog.find(choice.delete_prefix(BullionSpec::Choice::PRODUCT_PREFIX))
  end

  # My coins first (reused for later purchases), then catalogue coins per
  # metal, bars, and creating a new custom coin last.
  def bullion_choice_options(family)
    @bullion_choice_options ||= begin
      custom = family.bullion_specs.custom.includes(:security).sort_by(&:name)
        .map { |spec| [ spec.name, "#{BullionSpec::Choice::CUSTOM_PREFIX}#{spec.id}" ] }

      catalogue = BullionCatalog.products
        .group_by { |product| product.bar? ? "bar" : "coin_#{product.metal}" }
        .map do |group, products|
          [ t("trades.form.bullion_groups.#{group}", default: group.humanize),
            products.map { |product| [ product.display_name, "#{BullionSpec::Choice::PRODUCT_PREFIX}#{product.key}" ] } ]
        end

      groups = []
      groups << [ t("trades.form.bullion_groups.custom"), custom ] if custom.any?
      groups.concat(catalogue)
      groups << [ t("trades.form.bullion_groups.new_custom"),
                  [ [ t("trades.form.custom_bullion_new"), BullionSpec::Choice::NEW_CUSTOM ] ] ]
    end
  end

  # Preselects the picker with a holding's current coin or bar.
  def bullion_picker_defaults(spec)
    return {} if spec.nil?
    return { bullion_choice: "#{BullionSpec::Choice::CUSTOM_PREFIX}#{spec.id}" } if spec.custom?

    defaults = { bullion_choice: "#{BullionSpec::Choice::PRODUCT_PREFIX}#{spec.catalog_key}" }
    if BullionCatalog.find(spec.catalog_key)&.bar?
      defaults.merge(bullion_weight: spec.fine_weight_grams.to_s("F").sub(/\.0\z/, ""), bullion_weight_unit: "g")
    else
      defaults.merge(bullion_size: spec.size_key)
    end
  end

  def bullion_weight_unit_options
    BullionCatalog::WEIGHT_UNITS.keys.map { |unit| [ t("trades.form.weight_units.#{unit}"), unit ] }
  end

  def bullion_size_options(product)
    product.sizes.map { |size| [ size.label, size.key ] }
  end

  def bullion_metal_options
    BullionSpec::METALS.map { |metal| [ t("trades.form.metals.#{metal}"), metal ] }
  end
end
