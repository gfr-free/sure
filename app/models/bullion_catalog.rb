# Read-only catalogue of common bullion coins and bars, loaded from
# config/bullion_products.yml. Each product size maps to one shared offline
# Security, created on first use.
class BullionCatalog
  CONFIG_PATH = Rails.root.join("config", "bullion_products.yml")
  FORMS = %w[coin bar].freeze

  class UnknownProductError < StandardError; end

  Size = Data.define(:key, :label, :fine_weight_grams)

  Product = Data.define(:key, :name, :metal, :form, :sizes) do
    def size(key)
      sizes.find { |size| size.key == key.to_s }
    end
  end

  class << self
    def products
      @products ||= load_products(YAML.safe_load_file(CONFIG_PATH))
    end

    def find(key)
      products.find { |product| product.key == key.to_s }
    end

    # Idempotent: returns the existing Security when the product size was
    # already created, also when a concurrent request created it first.
    def security_for(product_key, size_key)
      product = find(product_key) or raise UnknownProductError, "Unknown bullion product: #{product_key}"
      size = product.size(size_key) or raise UnknownProductError, "Unknown size #{size_key} for #{product_key}"

      existing = BullionSpec.catalog.find_by(catalog_key: product.key, size_key: size.key)
      return existing.security if existing

      create_security(product, size)
    rescue ActiveRecord::RecordNotUnique
      BullionSpec.catalog.find_by!(catalog_key: product.key, size_key: size.key).security
    end

    def load_products(data)
      products = Array(data&.fetch("products", nil)).map { |entry| build_product(entry) }

      duplicate = products.map(&:key).tally.find { |_, count| count > 1 }
      raise ArgumentError, "Duplicate bullion product key: #{duplicate.first}" if duplicate

      products.freeze
    end

    private
      def create_security(product, size)
        BullionSpec.transaction(requires_new: true) do
          security = Security.create!(
            ticker: ticker_for(product, size),
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

      def ticker_for(product, size)
        "#{BullionSpec::TICKER_PREFIX}#{product.key}-#{size.key}".upcase.tr("_", "-")
      end

      def build_product(entry)
        key = entry.fetch("key").to_s
        metal = entry.fetch("metal").to_s
        form = entry.fetch("form").to_s
        raise ArgumentError, "Unknown metal #{metal} for #{key}" unless BullionSpec::METALS.include?(metal)
        raise ArgumentError, "Unknown form #{form} for #{key}" unless FORMS.include?(form)

        sizes = Array(entry.fetch("sizes")).map { |size| build_size(key, size) }
        raise ArgumentError, "No sizes for #{key}" if sizes.empty?
        raise ArgumentError, "Duplicate size key for #{key}" unless sizes.map(&:key).uniq.size == sizes.size

        Product.new(key: key, name: entry.fetch("name").to_s, metal: metal, form: form, sizes: sizes.freeze)
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

        Size.new(key: entry.fetch("key").to_s, label: entry.fetch("label").to_s, fine_weight_grams: grams.round(4))
      end
  end
end
