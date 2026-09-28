module ContractsHelper
  STATUS_TONES = {
    "active" => :success,
    "cancellation_sent" => :warning,
    "cancelled" => :info,
    "ended" => :neutral
  }.freeze

  def contract_status_pill(contract)
    status = contract.display_status
    label = if status == "cancelled" && contract.ends_on.present? && contract.open?
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
    return t("contracts.terms.unknown") if contract.notice_period_value.blank?

    period = t("contracts.terms.notice_units.#{contract.notice_period_unit}", count: contract.notice_period_value)
    return period if contract.notice_anchor.blank?

    t("contracts.terms.notice_with_anchor", period: period, anchor: t("contracts.notice_anchors.#{contract.notice_anchor}"))
  end

  def contract_annual_cost(cost)
    money, unconvertible = cost
    return t("contracts.cost_unknown") if money.nil?

    label = t("contracts.per_year", amount: format_money(money))
    unconvertible.to_i.positive? ? "#{label}*" : label
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
