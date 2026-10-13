module HoldingsHelper
  # Coins and bars are counted in pieces and their ticker is an internal code,
  # so their holdings read "pieces" and show what they are instead.
  def bullion_holding?(holding)
    BullionCatalog.kind_for_ticker(holding.ticker).present?
  end

  # Picks the "pieces" variant of a translation key for coins and bars:
  # ".shares" becomes ".pieces", ".per_share" ".per_piece", and a key that
  # names no unit gets a "_pieces" suffix.
  def holding_unit_key(holding, key)
    return key unless bullion_holding?(holding)
    return "#{key}_pieces" unless key.include?("share")

    key.sub("shares", "pieces").sub("share", "piece")
  end

  # Under the holding's name: its ticker, or "Coin", "Bar" or "Custom coin".
  def holding_subtitle(holding)
    kind = BullionCatalog.kind_for_ticker(holding.ticker)
    kind ? t("holdings.kinds.#{kind}") : holding.ticker
  end

  # The label/value pair of the drawer's security row.
  def holding_security_label(holding)
    kind = BullionCatalog.kind_for_ticker(holding.ticker)
    kind ? t("holdings.kinds.#{kind}") : t("holdings.show.security_label")
  end

  def holding_security_value(holding)
    bullion_holding?(holding) ? holding.name : holding.ticker
  end

  # Where a coin's or bar's price comes from, e.g. "Derived from Gold
  # (GC=F · Yahoo Finance) × 1 oz fine". Reads the setting only, so rendering
  # never creates the reference security.
  def bullion_price_source(spec)
    ticker, _mic = BullionSpec::PriceDeriver.reference_symbol(spec.metal)
    provider = BullionSpec::PriceDeriver.reference_provider
    source = [ ticker, t("securities.providers.#{provider}", default: provider.humanize) ].compact.join(" · ")

    t("holdings.show.bullion_price_source",
      metal: t("trades.form.metals.#{spec.metal}"),
      source: source.presence || t("holdings.show.unknown"),
      ounces: number_with_precision(spec.fine_troy_ounces, precision: 4, strip_insignificant_zeros: true))
  end
end
