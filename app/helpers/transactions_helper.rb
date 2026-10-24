module TransactionsHelper
  # A counterparty's own bank account identifier is arguably more sensitive
  # than the user's own account IBAN (it's a third party's number, not
  # something the viewing family controls), so it's masked to the last 4
  # characters by default -- matching the existing convention for the
  # user's own linked-account IBAN in
  # enable_banking_items/setup_accounts.html.erb -- rather than relying
  # solely on the opt-in Privacy Mode blur.
  def mask_counterparty_account_value(value)
    return value if value.blank? || value.length <= 4
    "•#{value.last(4)}"
  end

  # Returns [label, masked value] for the counterparty row, or nil when the
  # transaction carries no counterparty data. Only an actual IBAN is labelled
  # as one; the provider's generic account id gets a neutral label.
  def counterparty_account_display(transaction)
    if (iban = transaction.counterparty_iban.presence)
      [ t("transactions.show.counterparty_iban_label"), mask_counterparty_account_value(iban) ]
    elsif (account_id = transaction.counterparty_account_id.presence)
      [ t("transactions.show.counterparty_account_label"), mask_counterparty_account_value(account_id) ]
    end
  end

  # @param exclude [Array<String>] filter keys to leave out (e.g. the account
  #   tab doesn't apply to the account activity feed, which is already scoped
  #   to one account)
  # @return [Array<Hash>] the filters offered above the transaction list, each
  #   with the key its partial is named for, a translated label and an icon
  def transaction_search_filters(exclude: [])
    [
      { key: "account_filter", label: t("transactions.search.filters.account"), icon: "layers" },
      { key: "date_filter", label: t("transactions.search.filters.date"), icon: "calendar" },
      { key: "type_filter", label: t("transactions.search.filters.type"), icon: "tag" },
      { key: "status_filter", label: t("transactions.search.filters.status"), icon: "clock" },
      { key: "amount_filter", label: t("transactions.search.filters.amount"), icon: "hash" },
      { key: "category_filter", label: t("transactions.search.filters.category"), icon: "shapes" },
      { key: "tag_filter", label: t("transactions.search.filters.tag"), icon: "tags" },
      { key: "merchant_filter", label: t("transactions.search.filters.merchant"), icon: "store" },
      { key: "ai_filter", label: t("transactions.search.filters.ai"), icon: "sparkles" },
      { key: "attachment_filter", label: t("transactions.search.filters.attachment"), icon: "paperclip" }
    ].reject { |filter| exclude.include?(filter[:key]) }
  end

  # @param label [String] a stored investment_activity_label such as "Sweep In"
  # @return [String] its name in the current locale, or the label itself when
  #   it has no translation
  def investment_activity_label_name(label)
    t("transactions.activity_labels.#{label.parameterize(separator: "_")}", default: label)
  end

  # @param filter [Hash] one entry from transaction_search_filters
  # @return [String] the partial that renders that filter's controls
  def get_transaction_search_filter_partial_path(filter)
    "transactions/searches/filters/#{filter[:key]}"
  end

  # @return [Hash] the filter shown when the user has not picked one
  def get_default_transaction_search_filter
    transaction_search_filters[0]
  end

  # Shared between the transactions page and the account activity feed's
  # amount filter badge, so the label doesn't drift out of sync with the
  # options offered in filters/_amount_filter.html.erb.
  # @param operator [String, nil] "equal", "greater" or "less"
  # @return [String] the translated operator label
  def transaction_amount_operator_label(operator)
    case operator
    when "equal" then t("transactions.searches.search.equal_to")
    when "greater" then t("transactions.searches.search.greater_than")
    when "less" then t("transactions.searches.search.less_than")
    else operator.to_s
    end
  end

  # A split child is only folded under its parent when the user asked for
  # grouping and the current view is rendering grouped.
  #
  # @param entry [Entry] the entry being rendered
  # @param params_grouped [String, nil] the grouped param as it arrived
  # @return [Boolean] whether to render this entry inside its split group
  def in_split_group?(entry, params_grouped)
    entry.split_child? && Current.user.show_split_grouped? && params_grouped == "true"
  end

  # Fragment cache key for one row of the transactions list. Rendering a row
  # costs about 14 ms on a small self-hosted CPU (some 30 partials and
  # components), and a page of 100 rows re-rendered on every visit, filter
  # change or return from the drawer although rows rarely change. Everything
  # the row shows or branches on is part of the key, so any change renders
  # the row fresh:
  #
  # - the records it reads (entry, transaction, account, category, merchant,
  #   tags, transfer and its counterpart, the outflow's category an inflow
  #   row shows, the security a brokerage activity shows a logo for)
  # - per-user or per-request state (locale, user, family display settings,
  #   whether the user may annotate the account or see the counterpart,
  #   whether the entry is a split parent, grouped rendering, view context)
  # - the image build, so a deploy with new markup never serves old rows;
  #   skip_digest is on because the row renders DS::* components, which the
  #   ERB dependency tracker cannot digest (see account_sidebar_tabs)
  # - the Brandfetch settings that shape logo URLs
  #
  # Bump the version suffix when changing the row template or its partials.
  def transaction_row_cache_key(entry, view_ctx:, in_split_group:)
    transaction = entry.entryable
    transfer = transaction.transfer
    outflow_leg = transaction.transfer_as_outflow.present?
    counterpart = transfer && (outflow_leg ? transfer.to_account : transfer.from_account)
    outflow_category = transfer && (outflow_leg ? transaction.category : transfer.outflow_transaction&.category)
    split_parent = @split_parent_entry_ids ? @split_parent_entry_ids.include?(entry.id) : entry.split_parent?

    [
      "transaction_row_v1",
      ENV["BUILD_COMMIT_SHA"].presence,
      I18n.locale,
      Current.user&.id,
      Current.family&.currency,
      Current.family&.locale,
      view_ctx,
      in_split_group,
      split_parent,
      can_annotate_account?(entry.account),
      counterpart.present? && @accessible_account_ids&.include?(counterpart.id),
      Setting.brand_fetch_logo_size,
      Setting.brand_fetch_client_id.present?,
      entry.cache_key_with_version,
      transaction.cache_key_with_version,
      entry.account.cache_key_with_version,
      transaction.category&.cache_key_with_version,
      transaction.merchant&.cache_key_with_version,
      transaction.tags.map(&:cache_key_with_version).sort,
      transfer&.cache_key_with_version,
      counterpart&.cache_key_with_version,
      outflow_category&.cache_key_with_version,
      transaction.activity_security&.cache_key_with_version
    ]
  end

  # Whether the current user may annotate (e.g. re-tag) entries on this
  # account. Memoized per request so list rows don't query per row.
  def can_annotate_account?(account)
    return false unless Current.user

    @annotatable_account_ids ||= Account.annotatable_by(Current.user).pluck(:id).to_set
    @annotatable_account_ids.include?(account.id)
  end

  # ---- Transaction extra details helpers ----
  # Returns a structured hash describing extra details for a transaction.
  # Input can be a Transaction or an Entry (responds_to :transaction).
  # Structure:
  #   {
  #     kind: :simplefin | :plaid | :raw,
  #     simplefin: { payee:, description:, memo: },
  #     plaid: { original_description:, payment_channel:, transaction_code: },
  #     provider_extras: [ { key:, value:, multiline: } ],
  #       multiline marks values the view should render in a <pre> block
  #       rather than inline opposite their label.
  #     raw: String (pretty JSON) — only set for :raw, where we have no
  #       structured rendering for the provider
  #   }
  def build_transaction_extra_details(obj)
    tx = obj.respond_to?(:transaction) ? obj.transaction : obj
    return nil unless tx.respond_to?(:extra) && tx.extra.present?

    extra = tx.extra

    if extra.is_a?(Hash) && extra["simplefin"].present?
      sf = extra["simplefin"]
      simple = {
        payee: sf.is_a?(Hash) ? sf["payee"].presence : nil,
        description: sf.is_a?(Hash) ? sf["description"].presence : nil,
        memo: sf.is_a?(Hash) ? sf["memo"].presence : nil
      }.compact

      extras = []
      if sf.is_a?(Hash) && sf["extra"].is_a?(Hash) && sf["extra"].present?
        sf["extra"].each do |k, v|
          extras.concat(provider_extra_rows(provider_extra_field_label(k), v))
        end
      end

      # Same rule as the Plaid branch below. SimpleFIN always writes a pending
      # flag, so a transaction carrying nothing else would otherwise open an
      # Additional details section with no details in it.
      return nil if simple.blank? && extras.blank?

      {
        kind: :simplefin,
        simplefin: simple,
        plaid: {},
        provider_extras: extras,
        raw: nil
      }
    elsif extra.is_a?(Hash) && extra["plaid"].present?
      plaid = extra["plaid"]
      simple = {
        original_description: plaid.is_a?(Hash) ? plaid["original_description"].presence : nil,
        payment_channel: plaid.is_a?(Hash) ? plaid["payment_channel"].presence : nil,
        transaction_code: plaid.is_a?(Hash) ? plaid["transaction_code"].presence : nil
      }.compact

      extras = []
      if plaid.is_a?(Hash)
        if plaid["payment_meta"].is_a?(Hash) && plaid["payment_meta"].present?
          plaid["payment_meta"].each do |k, v|
            extras.concat(provider_extra_rows(t("transactions.show.plaid_payment_meta_label", name: provider_extra_field_label(k)), v))
          end
        end

        if plaid["counterparties"].is_a?(Array) && plaid["counterparties"].present?
          plaid["counterparties"].each_with_index do |counterparty, index|
            extras.concat(provider_extra_rows(t("transactions.show.plaid_counterparty_label", index: index + 1), counterparty))
          end
        end
      end

      # Only show Additional details when there is something beyond pending flags
      return nil if simple.blank? && extras.blank?

      {
        kind: :plaid,
        simplefin: {},
        plaid: simple,
        provider_extras: extras,
        # No raw dump: the structured rows above already cover the payload, and
        # the only fields they omit (pending, pending_transaction_id) are what
        # the pending badge communicates.
        raw: nil
      }
    else
      {
        kind: :raw,
        simplefin: {},
        plaid: {},
        provider_extras: [],
        # counterparty_iban/counterparty_account_id live in their own encrypted
        # columns and are shown masked above; an already-synced row from before
        # that change may still carry them here, so they never reach the raw dump.
        raw: pretty_json(extra.is_a?(Hash) ? extra.except("counterparty_iban", "counterparty_account_id") : extra)
      }
    end
  end

  # Flatten hashes into labeled rows; pretty-print remaining nested structures.
  #
  # `key` arrives already presentable — localized by the caller, or run through
  # provider_extra_field_label here. Nothing downstream reformats it, because a
  # composed label is part translation and part provider identifier and
  # `humanize` would lowercase the translated half.
  #
  # An empty value yields no row. A row with nothing opposite its label is noise,
  # and it made the extras non-blank, which defeated the guard that keeps an
  # empty Additional details section closed.
  def provider_extra_rows(key, value, depth: 0)
    value = value.reject { |item| blank_provider_extra?(item) } if value.is_a?(Array)
    return [] if blank_provider_extra?(value)

    label = key.to_s

    case value
    when Hash
      value.flat_map do |child_key, child_value|
        child = provider_extra_field_label(child_key)
        child_label = depth.zero? ? "#{label} · #{child}" : "#{label}.#{child}"
        provider_extra_rows(child_label, child_value, depth: depth + 1)
      end
    when Array
      if value.all? { |item| !item.is_a?(Hash) && !item.is_a?(Array) }
        [ provider_extra_row(label, value.join(", ")) ]
      else
        # Pass the raw value — provider_extra_row does the single encode. Handing
        # it a pretty_json string here would re-encode it into an escaped one-liner.
        [ provider_extra_row(label, value, multiline: true) ]
      end
    else
      [ provider_extra_row(label, value) ]
    end
  end

  # Builds one row for the view. The key arrives already presentable and is not
  # reformatted here, since a composed label is part translation and part
  # provider identifier.
  #
  # @param key [String] the label to show
  # @param value [Object] the provider value
  # @param multiline [Boolean] render in a block rather than opposite the label
  # @return [Hash] a row of { key:, value:, multiline: }
  def provider_extra_row(key, value, multiline: false)
    display = if multiline || value.is_a?(Hash) || value.is_a?(Array)
      pretty_json(value)
    else
      value
    end

    {
      key: key.to_s,
      value: display,
      multiline: multiline || value.is_a?(Hash) || value.is_a?(Array)
    }
  end

  # Provider field names are schema identifiers (reference_number,
  # confidence_level), so they get a translation where we know the field and
  # `humanize` otherwise — the set is open-ended and a provider can add to it
  # without us, which is better served by a readable fallback than a missing key.
  #
  # The key becomes part of an i18n lookup, so a blank or dotted one would be read
  # as a scope rather than a field name: "" resolves to the whole
  # provider_extra_fields hash, which then rendered as the label. Those fall back
  # to the humanized key, as does any lookup that comes back as something other
  # than a string.
  def provider_extra_field_label(key)
    fallback = key.to_s.humanize
    return fallback if key.to_s.strip.empty? || key.to_s.include?(".")

    label = t("transactions.show.provider_extra_fields.#{key}", default: fallback)
    label.is_a?(String) ? label : fallback
  end

  # Nothing worth a row: nil, an empty or whitespace-only string, or an empty
  # collection. false and 0 are real values a provider meant to report, so they stay.
  #
  # @param value [Object] a provider value
  # @return [Boolean] whether the value has nothing to show
  def blank_provider_extra?(value)
    case value
    when nil then true
    when String then value.strip.empty?
    when Array, Hash then value.empty?
    else false
    end
  end

  # Provider payloads are arbitrary JSON, so anything that cannot be generated
  # falls back to its string form rather than raising in a view.
  #
  # @param value [Object] any provider value
  # @return [String] indented JSON, or the value's string form
  def pretty_json(value)
    JSON.pretty_generate(value)
  rescue StandardError
    value.to_s
  end

  # Options for the convert-to-trade security picker: label, id and the data
  # its price check reads. That check compares against the price the
  # transaction implies, so only a quote converted to `currency` carries
  # data-price-cents. Without a rate the quote is still shown, under its own
  # currency. The securities share one rate lookup per quote currency and day.
  def convert_to_trade_security_options(securities, currency)
    rates = {}
    securities.map do |security|
      price = security.current_price_in(currency, rates: rates)
      shown_price = price || security.current_price
      label = security.ticker.to_s.dup
      label << " (#{format_money(shown_price)})" if shown_price
      label << " - #{security.name.truncate(25)}" if security.name.present?
      price_cents = price ? (price.amount * 100).to_i : nil
      [ label, security.id, { "data-price-cents" => price_cents, "data-ticker" => security.ticker } ]
    end
  end
end
