# Read-only catalogue of common bullion coins and bars, loaded from
# config/bullion_products.yml. Each coin size, and each bar product at a given
# weight, maps to one shared offline Security, created on first use.
class BullionCatalog
  CONFIG_PATH = Rails.root.join("config", "bullion_products.yml")
  FORMS = %w[coin bar].freeze

  # Units a bar weight can be entered in, as grams per unit.
  WEIGHT_UNITS = { "g" => BigDecimal("1"), "kg" => BigDecimal("1000"), "oz" => BullionSpec::TROY_OUNCE_GRAMS }.freeze
  # Large enough for any traded bar (the heaviest common ones are 12.5 kg gold
  # and 30 kg silver), small enough to catch a typo in the unit.
  MAX_BAR_GRAMS = BullionSpec::MAX_FINE_WEIGHT_GRAMS

  class UnknownProductError < StandardError; end
  class InvalidWeightError < StandardError; end

  Size = Data.define(:key, :label, :fine_weight_grams, :face_value) do
    def initialize(key:, label:, fine_weight_grams:, face_value: nil)
      super
    end
  end

  Product = Data.define(:key, :name, :metal, :form, :sizes, :face_value_currency) do
    def size(key)
      sizes.find { |size| size.key == key.to_s }
    end

    def bar?
      form == "bar"
    end

    # The stored name is English; this is the one to show.
    def display_name
      I18n.t("bullion_catalog.products.#{key}", default: name)
    end
  end

  class << self
    def products
      @products ||= load_products(YAML.safe_load_file(CONFIG_PATH))
    end

    def find(key)
      products.find { |product| product.key == key.to_s }
    end

    # A catalogue coin's face value as Money, nil when it has none.
    def face_value_for(product_key, size_key)
      product = find(product_key)
      amount = product&.size(size_key)&.face_value
      Money.new(amount, product.face_value_currency) if amount
    end

    # Idempotent: returns the existing Security when the coin size was already
    # created, also when a concurrent request created it first.
    def security_for(product_key, size_key)
      product = find(product_key) or raise UnknownProductError, "Unknown bullion product: #{product_key}"
      raise UnknownProductError, "#{product_key} is a bar; its weight is entered, not picked" if product.bar?
      size = product.size(size_key) or raise UnknownProductError, "Unknown size #{size_key} for #{product_key}"

      find_or_create_security(product, size)
    end

    # A bar of the given weight. Bars of the same product and weight share one
    # Security, so 1 kg and 1000 g end up in the same holding.
    def bar_security_for(product_key, weight, unit)
      product = find(product_key) or raise UnknownProductError, "Unknown bullion product: #{product_key}"
      raise UnknownProductError, "#{product_key} is a coin; pick one of its sizes" unless product.bar?

      grams = bar_grams(weight, unit)
      # A bar is told apart by metal and weight alone, so "1 kg" and "1000 g"
      # are the same bar. Looking it up by weight also finds bars saved under
      # an older size key such as "1kg".
      existing = BullionSpec.catalog.where(catalog_key: product.key, fine_weight_grams: grams).order(:created_at).first
      return existing.security if existing

      size = Size.new(key: bar_size_key(grams), label: bar_label(grams, locale: :en), fine_weight_grams: grams)
      find_or_create_security(product, size)
    end

    # The name of a catalogue Security in the current locale, or nil for any
    # other Security (custom coins included). Read from the ticker so a list of
    # holdings needs no extra query.
    def localized_name(ticker)
      return nil unless ticker.to_s.start_with?(BullionSpec::TICKER_PREFIX)

      coin = coin_tickers[ticker]
      return "#{coin.first.display_name} #{coin.last.label}" if coin

      bar_products.each do |product|
        weight = ticker.delete_prefix("#{ticker_stem(product)}-")
        next if weight == ticker

        grams = bar_ticker_grams(weight)
        return "#{product.display_name} #{bar_label(grams)}" if grams
      end

      nil
    end

    # :coin, :bar or :custom_coin for a bullion ticker, nil for anything else.
    # Read from the ticker so lists of holdings need no extra query.
    def kind_for_ticker(ticker)
      ticker = ticker.to_s
      return nil unless ticker.start_with?(BullionSpec::TICKER_PREFIX)
      return :custom_coin if ticker.start_with?(BullionSpec::CUSTOM_TICKER_PREFIX)
      return :bar if bar_products.any? { |product| ticker.start_with?("#{ticker_stem(product)}-") }

      :coin
    end

    # "1 kg", "1 oz" or "250 g": whole kilograms and whole or fractional troy
    # ounces read as such, everything else in grams.
    def bar_label(grams, locale: I18n.locale)
      if grams >= 1000 && (grams % 1000).zero?
        "#{format_weight(grams / 1000, locale)} kg"
      elsif (ounces = (grams / BullionSpec::TROY_OUNCE_GRAMS).round(2)).positive? &&
            (ounces * BullionSpec::TROY_OUNCE_GRAMS).round(4) == grams
        "#{format_weight(ounces, locale)} oz"
      else
        "#{format_weight(grams, locale)} g"
      end
    end

    def load_products(data)
      products = Array(data&.fetch("products", nil)).map { |entry| build_product(entry) }

      duplicate = products.map(&:key).tally.find { |_, count| count > 1 }
      raise ArgumentError, "Duplicate bullion product key: #{duplicate.first}" if duplicate

      products.freeze
    end

    private
      def find_or_create_security(product, size)
        existing = BullionSpec.catalog.find_by(catalog_key: product.key, size_key: size.key)
        return existing.security if existing

        create_security(product, size)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # A concurrent request created the same product size first.
        existing = BullionSpec.catalog.find_by(catalog_key: product.key, size_key: size.key)
        raise unless existing

        existing.security
      end

      def create_security(product, size)
        BullionSpec.transaction(requires_new: true) do
          security = Security.create!(
            ticker: "#{ticker_stem(product)}-#{size.key}".upcase,
            name: "#{product.name} #{size.label}",
            **BullionSpec.security_attributes
          )
          BullionSpec.create!(
            security: security,
            metal: product.metal,
            fine_weight_grams: size.fine_weight_grams,
            catalog_key: product.key,
            size_key: size.key
          )
          security
        end
      end

      def ticker_stem(product)
        "#{BullionSpec::TICKER_PREFIX}#{product.key}".upcase.tr("_", "-")
      end

      def coin_tickers
        @coin_tickers ||= products.reject(&:bar?).each_with_object({}) do |product, map|
          product.sizes.each { |size| map["#{ticker_stem(product)}-#{size.key}".upcase] = [ product, size ] }
        end.freeze
      end

      def bar_products
        products.select(&:bar?)
      end

      def bar_grams(weight, unit)
        factor = WEIGHT_UNITS[unit.to_s] or raise InvalidWeightError, "Unknown weight unit: #{unit}"
        amount = BigDecimal(weight.to_s.strip.tr(",", "."))
        grams = (amount * factor).round(4)
        raise InvalidWeightError, "Bar weight must be positive" unless grams.positive?
        raise InvalidWeightError, "Bar weight is above #{MAX_BAR_GRAMS} g" if grams > MAX_BAR_GRAMS

        grams
      rescue ArgumentError, TypeError
        raise InvalidWeightError, "Invalid bar weight: #{weight.inspect}"
      end

      # "1000G" and the older size keys "1KG" and "1OZ" from a bar's ticker.
      def bar_ticker_grams(weight)
        amount, unit = weight.match(/\A(\d+(?:\.\d+)?)(G|KG|OZ)\z/)&.captures
        return nil unless amount

        (BigDecimal(amount) * WEIGHT_UNITS.fetch(unit.downcase)).round(4)
      end

      # Grams without trailing zeros: "100g", "31.1035g".
      def bar_size_key(grams)
        "#{grams.to_s("F").delete_suffix(".0")}g"
      end

      def format_weight(value, locale)
        ActiveSupport::NumberHelper.number_to_rounded(value, precision: 4, strip_insignificant_zeros: true, locale: locale)
      end

      def build_product(entry)
        key = entry.fetch("key").to_s
        metal = entry.fetch("metal").to_s
        form = entry.fetch("form").to_s
        raise ArgumentError, "Unknown metal #{metal} for #{key}" unless BullionSpec::METALS.include?(metal)
        raise ArgumentError, "Unknown form #{form} for #{key}" unless FORMS.include?(form)

        sizes = Array(entry["sizes"]).map { |size| build_size(key, size) }
        if form == "bar"
          raise ArgumentError, "Bar #{key} lists sizes; a bar's weight is entered on the trade" if sizes.any?
        else
          raise ArgumentError, "No sizes for #{key}" if sizes.empty?
          raise ArgumentError, "Duplicate size key for #{key}" unless sizes.map(&:key).uniq.size == sizes.size
        end

        currency = entry["face_value_currency"].presence&.to_s
        if sizes.any?(&:face_value)
          raise ArgumentError, "#{key} lists face values but no face_value_currency" if currency.nil?
          begin
            Money::Currency.new(currency)
          rescue Money::Currency::UnknownCurrencyError
            raise ArgumentError, "Unknown face_value_currency #{currency} for #{key}"
          end
        elsif currency
          raise ArgumentError, "#{key} has a face_value_currency but no face values"
        end

        Product.new(key: key, name: entry.fetch("name").to_s, metal: metal, form: form, sizes: sizes.freeze, face_value_currency: currency)
      end

      def build_size(product_key, entry)
        grams =
          if entry.key?("fine_grams")
            BigDecimal(entry["fine_grams"].to_s)
          elsif entry.key?("fine_oz")
            BigDecimal(entry["fine_oz"].to_s) * BullionSpec::TROY_OUNCE_GRAMS
          end
        raise ArgumentError, "Size #{entry["key"]} of #{product_key} needs fine_grams or fine_oz" if grams.nil?
        raise ArgumentError, "Size #{entry["key"]} of #{product_key} needs a positive weight" unless grams.positive?

        face_value = BigDecimal(entry["face_value"].to_s) if entry.key?("face_value")
        if face_value && !face_value.positive?
          raise ArgumentError, "Size #{entry["key"]} of #{product_key} needs a positive face value"
        end

        Size.new(key: entry.fetch("key").to_s, label: entry.fetch("label").to_s, fine_weight_grams: grams.round(4), face_value: face_value)
      end
  end
end
