# A read-only rate store for `Money#exchange_to` (via `Money.new(..., store:)`)
# that answers from stored rates only: it never calls the provider, so a
# missing rate raises Money::ConversionError as it would with no provider
# configured. Rates are loaded once per (to, date) for every currency passed
# in, so converting many rows costs a fixed number of queries instead of one or
# two per row.
class ExchangeRate::CachedStore
  def initialize(currencies = [], to:, date: Date.current)
    @rates = {}
    preload(currencies, to: to, date: date)
  end

  def find_or_fetch_rate(from:, to:, date: Date.current)
    preload([ from ], to: to, date: date) unless @rates.key?([ from, to, date ])
    @rates[[ from, to, date ]]
  end

  private
    def preload(currencies, to:, date:)
      to = Money::Currency.new(to).iso_code
      wanted = currencies.compact.map { |c| Money::Currency.new(c).iso_code }.uniq - [ to ]
      wanted.reject! { |c| @rates.key?([ c, to, date ]) }
      return if wanted.empty?

      found = ExchangeRate.cached_rates_for(wanted, to: to, date: date)
      wanted.each { |c| @rates[[ c, to, date ]] = found[c] }
    end
end
