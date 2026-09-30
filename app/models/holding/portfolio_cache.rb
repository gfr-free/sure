class Holding::PortfolioCache
  attr_reader :account, :use_holdings

  class SecurityNotFound < StandardError
    def initialize(security_id, account_id)
      super("Security id=#{security_id} not found in portfolio cache for account #{account_id}.  This should not happen unless securities were preloaded incorrectly.")
    end
  end

  def initialize(account, use_holdings: false, security_ids: nil)
    @account = account
    @use_holdings = use_holdings
    @security_ids = security_ids
    load_prices
  end

  def get_trades(date: nil)
    if date.blank?
      trades
    else
      trades_by_date[date]&.dup || []
    end
  end

  def get_price(security_id, date, source: nil)
    security = @security_cache[security_id]
    raise SecurityNotFound.new(security_id, account.id) unless security

    price_with_priority = if source.present?
      security[:prices_by_date_and_source][[ date, source ]]
    else
      security[:prices_by_date][date]
    end

    return nil unless price_with_priority

    price = price_with_priority.price
    return nil unless price

    price_money = Money.new(price.price, price.currency)

    begin
      converted_amount = price_money.exchange_to(account.currency, date: date).amount
    rescue Money::ConversionError
      converted_amount = price.price
    end

    Security::Price.new(
      security_id: security_id,
      date: price.date,
      price: converted_amount,
      currency: account.currency
    )
  end

  def get_securities
    @security_cache.map { |_, v| v[:security] }
  end

  private
    PriceWithPriority = Data.define(:price, :priority, :source)

    # A trade seen on today's share basis: a share bought before a 1:4 split
    # counts as four at a quarter of the price, so quantity times price (and so
    # cost basis and realized gains) is unchanged.
    class SplitAdjustedTrade < SimpleDelegator
      def initialize(trade, factor)
        super(trade)
        @factor = factor
      end

      def qty
        __getobj__.qty && __getobj__.qty * @factor
      end

      def price
        __getobj__.price && __getobj__.price / @factor
      end
    end

    class SplitAdjustedEntry < SimpleDelegator
      def initialize(entry, factor)
        super(entry)
        @entryable = SplitAdjustedTrade.new(entry.entryable, factor)
      end

      attr_reader :entryable
    end

    def raw_trades
      @raw_trades ||= account.entries.includes(entryable: :security).trades.chronological.to_a
    end

    def trades
      @trades ||= split_adjust(raw_trades)
    end

    # Loaded with the securities in load_prices, before any trade is adjusted.
    attr_reader :split_schedule

    def split_adjust(entries)
      return entries if split_schedule.empty?

      entries.filter_map do |entry|
        trade = entry.entryable
        next if split_schedule.covers_broker_split_trade?(trade, entry.date)

        factor = split_schedule.factor_after(trade.security_id, entry.date)
        factor == 1 ? entry : SplitAdjustedEntry.new(entry, factor)
      end
    end

    # Providers that quote raw historical prices are brought onto today's share
    # basis here; split-adjusted providers already are.
    def split_adjust_price(price, factor)
      return price if factor == 1

      Security::Price.new(
        security_id: price.security_id,
        date: price.date,
        price: price.price / factor,
        currency: price.currency
      )
    end

    def prices_split_adjusted?(security)
      provider = security.offline? ? nil : security.price_data_provider
      provider.present? && provider.split_adjusted_prices?
    end

    def trades_by_date
      @trades_by_date ||= trades.group_by(&:date)
    end

    def trades_by_security_id
      @trades_by_security_id ||= trades.group_by { |t| t.entryable.security_id }
    end

    def holdings
      @holdings ||= account.holdings.chronological.to_a
    end

    def holdings_by_security_id
      @holdings_by_security_id ||= holdings.group_by(&:security_id)
    end

    def collect_unique_securities
      ids = raw_trades.map { |entry| entry.entryable.security_id }.uniq
      ids |= holdings_by_security_id.keys if use_holdings
      ids &= @security_ids if @security_ids

      Security.where(id: ids).to_a
    end

    # Loads all known prices for all securities in the account with priority based on source:
    # 1 - DB or provider prices
    # 2 - Trade prices
    # 3 - Holding prices
    def load_prices
      @security_cache = {}
      securities = collect_unique_securities

      Rails.logger.info "Preloading #{securities.size} securities for account #{account.id}"

      security_ids = securities.map(&:id)
      @split_schedule = Security::SplitSchedule.load(security_ids: security_ids, family_id: account.family_id)

      # Bulk-load all DB prices for all securities in one query, grouped by security_id
      db_prices_by_security_id = Security::Price
        .where(security_id: security_ids, date: account.start_date..Date.current)
        .group_by(&:security_id)

      securities.each do |security|
        Rails.logger.info "Loading security: ID=#{security.id} Ticker=#{security.ticker}"

        adjust_db_prices = split_schedule.splits_for?(security.id) && !prices_split_adjusted?(security)

        # High priority prices from DB (synced from provider)
        db_prices = (db_prices_by_security_id[security.id] || []).map do |price|
          if adjust_db_prices
            price = split_adjust_price(price, split_schedule.factor_after(security.id, price.date))
          end

          PriceWithPriority.new(
            price: price,
            priority: 1,
            source: "db"
          )
        end

        # Medium priority prices from trades
        # Exclude income entries (interest/dividend) — they are non-trading
        # events with qty=0 and their zero price would clobber the security's
        # market price on that date in the ForwardCalculator, producing a
        # zero-amount holding.  Use qty (the same heuristic as
        # Balance::BaseCalculator) rather than price to avoid blocking
        # non-income zero-price trades such as Questrade journal transfers.
        trade_prices = (trades_by_security_id[security.id] || [])
          .reject { |t| t.entryable.qty == 0 }
          .map do |trade|
            PriceWithPriority.new(
              price: Security::Price.new(
                security: security,
                price: trade.entryable.price,
                currency: trade.entryable.currency,
                date: trade.date
              ),
              priority: 2,
              source: "trade"
            )
          end

        # Low priority prices from holdings (if applicable)
        holding_prices = if use_holdings
          (holdings_by_security_id[security.id] || []).map do |holding|
            price = Security::Price.new(
              security: security,
              price: holding.price,
              currency: holding.currency,
              date: holding.date
            )

            # A provider's holding snapshot is quoted on the basis of its own
            # day. Calculated holdings are already on today's basis.
            if holding.account_provider_id.present?
              price = split_adjust_price(price, split_schedule.factor_after(security.id, holding.date))
            end

            PriceWithPriority.new(
              price: price,
              priority: 3,
              source: "holding"
            )
          end
        else
          []
        end

        all_prices = db_prices + trade_prices + holding_prices

        # Index by date for O(1) lookup in get_price instead of O(N) linear scan
        prices_by_date = all_prices.group_by { |p| p.price.date }
          .transform_values { |ps| ps.min_by(&:priority) }
        prices_by_date_and_source = all_prices.group_by { |p| [ p.price.date, p.source ] }
          .transform_values { |ps| ps.min_by(&:priority) }

        @security_cache[security.id] = {
          security: security,
          prices_by_date: prices_by_date,
          prices_by_date_and_source: prices_by_date_and_source
        }
      end
    end
end
