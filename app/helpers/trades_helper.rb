module TradesHelper
  BULLION_ACCOUNT_SUBTYPES = %w[precious_metals gold].freeze

  # The trade form reloads itself (query params) when a choice changes the
  # fields it shows, and re-renders from the submitted model params on errors.
  def trade_form_param(key)
    params[key].presence || params.dig(:model, key).presence
  end

  def trade_holding_kind(account)
    kind = trade_form_param(:holding_kind)
    return kind if Trade::CreateForm::HOLDING_KINDS.include?(kind)

    BULLION_ACCOUNT_SUBTYPES.include?(account&.subtype) ? "bullion" : "security"
  end

  def trade_holding_kind_options
    Trade::CreateForm::HOLDING_KINDS.map { |kind| [ t("trades.form.holding_kinds.#{kind}"), kind ] }
  end

  def trade_bullion_product
    BullionCatalog.find(trade_form_param(:bullion_product)) || BullionCatalog.products.first
  end

  # Grouped as gold coins, silver coins and bars, in catalogue order.
  def bullion_product_options
    BullionCatalog.products
      .group_by { |product| product.form == "bar" ? "bar" : "coin_#{product.metal}" }
      .map do |group, products|
        [ t("trades.form.bullion_groups.#{group}", default: group.humanize), products.map { |product| [ product.name, product.key ] } ]
      end
  end

  def bullion_size_options(product)
    product.sizes.map { |size| [ size.label, size.key ] }
  end

  def custom_bullion_options(family)
    specs = family.bullion_specs.custom.includes(:security).sort_by(&:name)
    specs.map { |spec| [ spec.name, spec.id ] } +
      [ [ t("trades.form.custom_bullion_new"), Trade::CreateForm::NEW_CUSTOM_BULLION ] ]
  end

  def bullion_metal_options
    BullionSpec::METALS.map { |metal| [ t("trades.form.metals.#{metal}"), metal ] }
  end
end
