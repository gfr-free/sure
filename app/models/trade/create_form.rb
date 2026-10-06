class Trade::CreateForm
  include ActiveModel::Model

  SECURITY_TRADE_LABELS = {
    "buy" => "Buy",
    "sell" => "Sell",
    "sweep_in" => "Sweep In",
    "sweep_out" => "Sweep Out",
    "reinvestment" => "Reinvestment"
  }.freeze

  CASH_TRADE_LABELS = {
    "dividend" => "Dividend",
    "interest" => "Interest",
    "fee" => "Fee"
  }.freeze

  ACTIVITY_LABELS = SECURITY_TRADE_LABELS.merge(CASH_TRADE_LABELS).freeze
  TRANSFER_TYPES = %w[deposit withdrawal].freeze
  SUPPORTED_TYPES = (ACTIVITY_LABELS.keys + TRANSFER_TYPES).freeze

  # What a buy or sell trades: a listed security, a catalogue coin or bar, or a
  # family's own coin (see BullionCatalog and BullionSpec).
  HOLDING_KINDS = %w[security bullion custom_bullion].freeze
  NEW_CUSTOM_BULLION = "new".freeze

  attr_accessor :account, :date, :amount, :currency, :qty,
                :price, :fee, :ticker, :manual_ticker, :type, :transfer_account_id,
                :holding_kind, :bullion_product, :bullion_size, :custom_bullion_id,
                :custom_bullion_name, :custom_bullion_metal, :custom_bullion_fine_grams

  # Either creates a trade, transaction, or transfer based on type
  # Returns the model, regardless of success or failure
  def create
    case type
    when *SECURITY_TRADE_LABELS.keys
      create_trade
    when "dividend"
      create_dividend_income
    when "interest"
      create_interest_income
    when "fee"
      create_fee
    when "deposit", "withdrawal"
      create_transfer
    end
  end

  private
    # Users can either look up a ticker from a provider or enter a manual, "offline" ticker (that we won't fetch prices for)
    def security
      parsed = ticker.present? ? Security.parse_combobox_id(ticker) : { ticker: manual_ticker }
      return nil if parsed[:ticker].blank?

      Security::Resolver.new(
        parsed[:ticker],
        exchange_operating_mic: parsed[:exchange_operating_mic],
        price_provider: parsed[:price_provider]
      ).resolve
    end

    def ticker_present?
      ticker.present? || manual_ticker.present?
    end

    def bullion_trade?
      holding_kind.in?(%w[bullion custom_bullion])
    end

    def trade_security
      case holding_kind
      when "bullion" then catalog_bullion_security
      when "custom_bullion" then custom_bullion_security
      else security
      end
    end

    def catalog_bullion_security
      BullionCatalog.security_for(bullion_product, bullion_size)
    rescue BullionCatalog::UnknownProductError
      nil
    end

    # An existing custom coin of the family, or a new one from the inline fields.
    def custom_bullion_security
      if custom_bullion_id.present? && custom_bullion_id != NEW_CUSTOM_BULLION
        return account.family.bullion_specs.custom.find_by(id: custom_bullion_id)&.security
      end

      BullionSpec.create_custom!(
        family: account.family,
        name: custom_bullion_name.to_s.strip,
        metal: custom_bullion_metal,
        fine_weight_grams: custom_bullion_fine_grams
      ).security
    end

    def security_error_key
      bullion_trade? ? "trades.form.trade_requires_bullion" : "trades.form.trade_requires_security"
    end

    # A new custom coin is only kept when its first trade saves too.
    def create_trade
      trade_entry = nil

      Entry.transaction do
        trade_entry = build_trade_entry
        raise ActiveRecord::Rollback if trade_entry.errors.any? || !trade_entry.save
      end

      if trade_entry.persisted?
        trade_entry.lock_saved_attributes!
        account.sync_later
      end

      trade_entry
    end

    def build_trade_entry
      sec = trade_security

      unless sec
        entry = account.entries.build(entryable: Trade.new)
        entry.errors.add(:base, I18n.t(security_error_key))
        return entry
      end

      signed_qty = sell_side_trade? ? -qty.to_d.abs : qty.to_d.abs
      signed_amount = signed_qty * price.to_d + fee.to_d
      label = SECURITY_TRADE_LABELS.fetch(type)

      account.entries.new(
        name: trade_name(label, signed_qty.abs, bullion_trade? ? sec.name : sec.ticker),
        date: date,
        amount: signed_amount,
        currency: currency,
        entryable: Trade.new(
          qty: signed_qty,
          price: price,
          fee: fee.to_d,
          currency: currency,
          security: sec,
          investment_activity_label: label
        )
      )
    rescue ActiveRecord::RecordInvalid => e
      entry = account.entries.build(entryable: Trade.new)
      entry.errors.add(:base, e.record.errors.full_messages.to_sentence)
      entry
    end

    # Dividends are always a Trade. Security is required.
    def create_dividend_income
      unless ticker_present?
        entry = account.entries.build(entryable: Trade.new)
        entry.errors.add(:base, I18n.t("trades.form.dividend_requires_security"))
        return entry
      end

      begin
        sec = security
        label = CASH_TRADE_LABELS.fetch("dividend")
        create_income_trade(sec: sec, label: label, name: "#{label}: #{sec.ticker}")
      rescue => e
        Rails.logger.warn("Dividend security resolution failed: #{e.class} - #{e.message}")
        entry = account.entries.build(entryable: Trade.new)
        entry.errors.add(:base, I18n.t("trades.form.dividend_requires_security"))
        entry
      end
    end

    # Interest in an investment account is always a Trade.
    # Falls back to a synthetic cash security when none is selected.
    def create_interest_income
      sec = ticker_present? ? security : Security.cash_for(account, currency: currency)
      label = CASH_TRADE_LABELS.fetch("interest")
      name = sec.cash? ? label : "#{label}: #{sec.ticker}"
      create_income_trade(sec: sec, label: label, name: name)
    end

    def create_fee
      sec = ticker_present? ? security : Security.cash_for(account, currency: currency)
      label = CASH_TRADE_LABELS.fetch("fee")
      name = sec.cash? ? label : "#{label}: #{sec.ticker}"
      create_income_trade(sec: sec, label: label, name: name, amount_sign: 1)
    end

    def create_income_trade(sec:, label:, name:, amount_sign: -1)
      entry = account.entries.build(
        name: name,
        date: date,
        amount: amount.to_d.abs * amount_sign,
        currency: currency,
        entryable: Trade.new(
          qty: 0,
          price: 0,
          fee: 0,
          currency: currency,
          security: sec,
          investment_activity_label: label
        )
      )

      if entry.save
        entry.lock_saved_attributes!
        account.sync_later
      end

      entry
    end

    def sell_side_trade?
      %w[sell sweep_out].include?(type)
    end

    def trade_name(label, quantity, ticker)
      return Trade.build_name(type, quantity, ticker) if %w[buy sell].include?(type)

      "#{label} #{quantity.to_d} shares of #{ticker}"
    end

    def create_transfer
      if transfer_account_id.present?
        from_account_id = type == "withdrawal" ? account.id : transfer_account_id
        to_account_id = type == "withdrawal" ? transfer_account_id : account.id

        Transfer::Creator.new(
          family: account.family,
          source_account_id: from_account_id,
          destination_account_id: to_account_id,
          date: date,
          amount: amount
        ).create
      else
        create_unlinked_transfer
      end
    end

    # If user doesn't provide the reciprocal account, it's a regular transaction
    def create_unlinked_transfer
      signed_amount = type == "deposit" ? amount.to_d * -1 : amount.to_d

      entry = account.entries.build(
        name: signed_amount < 0 ? "Deposit to #{account.name}" : "Withdrawal from #{account.name}",
        date: date,
        amount: signed_amount,
        currency: currency,
        entryable: Transaction.new
      )

      if entry.save
        entry.lock_saved_attributes!
        account.sync_later
      end

      entry
    end
end
