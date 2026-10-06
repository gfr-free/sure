module ContractsHelper
  STATUS_TONES = {
    "active" => :success,
    "ending" => :warning,
    "ended" => :neutral
  }.freeze

  def contract_status_pill(contract)
    status = contract.display_status
    label = if status == "ending"
      t("contracts.status_until", date: l(contract.ends_on, format: :long))
    else
      t("contracts.statuses.#{status}")
    end

    render DS::Pill.new(label: label, tone: STATUS_TONES.fetch(status, :neutral), marker: false)
  end

  # The notice deadline when it is close enough to act on (the same window the
  # reminder insight uses), for the list row.
  def contract_upcoming_deadline(contract)
    deadline = contract.notice_deadline
    deadline if deadline && deadline <= Date.current + Insight::Generators::ContractGenerator::DEADLINE_WINDOW_DAYS
  end

  # Portal and document links are validated as http(s) on save; checked again
  # here so a link is only ever rendered for a web address.
  def contract_safe_url(url)
    url if Contract.http_url?(url)
  end

  def contract_kind_label(kind)
    t("contracts.kinds.#{kind}")
  end

  def contract_avatar(contract, size: "lg")
    if contract.merchant.respond_to?(:logo_url) && contract.merchant.logo_url.present?
      image_tag Setting.transform_brand_fetch_url(contract.merchant.logo_url),
                class: "w-9 h-9 rounded-full shrink-0", loading: "lazy", alt: ""
    else
      render DS::FilledIcon.new(icon: contract.icon, size: size, rounded: true, variant: :container)
    end
  end

  # "24 months", "indefinite": how long the contract binds before it can end.
  def contract_minimum_term(contract)
    return t("contracts.terms.none") if contract.minimum_term_months.blank? || contract.minimum_term_months.zero?

    t("contracts.terms.months", count: contract.minimum_term_months)
  end

  def contract_renewal(contract)
    return t("contracts.terms.indefinite") if contract.renewal_period_months.blank?

    t("contracts.terms.renews_every", count: contract.renewal_period_months)
  end

  # "3 months to the end of the term"
  def contract_notice(contract)
    return t("contracts.terms.not_required") if contract.notice_not_required?
    return t("contracts.terms.unknown") if contract.notice_period_value.blank?

    period = t("contracts.terms.notice_units.#{contract.notice_period_unit}", count: contract.notice_period_value)
    return period if contract.notice_anchor.blank?

    t("contracts.terms.notice_with_anchor", period: period, anchor: t("contracts.notice_anchors.#{contract.notice_anchor}"))
  end

  # Rent without the operating-costs prepayment, per month, when the linked
  # bills give the rent and the prepayment is recorded.
  def contract_cold_rent(contract, annual_cost)
    advance = contract.typed_detail("operating_costs_advance") if contract.rent?
    return if advance.nil? || annual_cost.nil? || annual_cost.zero?

    cold = annual_cost / 12 - Money.new(advance, annual_cost.currency)
    cold if cold.positive?
  end

  def contract_annual_cost(cost)
    amount = contract_annual_amount(cost)
    amount ? t("contracts.per_year", amount: amount) : t("contracts.cost_unknown")
  end

  # The yearly cost from an annual_costs_for result, or nil when unknown. Bills
  # without an exchange rate show in their own currency next to the converted
  # total, which is left out when nothing could be converted.
  def contract_annual_amount(cost)
    money, _, unconverted = cost
    return if money.nil?

    unconverted = unconverted.to_h.values
    parts = unconverted.any? && money.zero? ? [] : [ money ]
    (parts + unconverted).map { |part| format_money(part) }.join(" + ")
  end

  # The number a viewer is allowed to see: in full for anyone who may edit the
  # contract, masked for a read-only share.
  def contract_number_for(contract, attribute)
    value = contract.public_send(attribute)
    return if value.blank?

    contract.numbers_visible_to?(Current.user) ? value : Contract.mask(value)
  end

  def contract_kind_options
    Contract.kind_options
  end

  def contract_notice_unit_options
    Contract.notice_period_units.keys.map { |unit| [ t("contracts.form.units.#{unit}"), unit ] }
  end

  def contract_notice_anchor_options
    Contract.notice_anchors.keys.map { |anchor| [ t("contracts.notice_anchors.#{anchor}"), anchor ] }
  end

  def contract_share_permission_options(user)
    permissions = user.guest? ? %w[read_only] : ContractShare::PERMISSIONS
    permissions.map { |permission| [ t("contracts.sharings.permissions.#{permission}"), permission ] }
  end
end
