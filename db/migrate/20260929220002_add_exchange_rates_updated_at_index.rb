class AddExchangeRatesUpdatedAtIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # IncomeStatement#cache_freshness_key reads ExchangeRate.maximum(:updated_at)
  # on every dashboard, report and budget render. No if_not_exists, see the
  # entries index migration.
  def change
    add_index :exchange_rates, :updated_at, algorithm: :concurrently
  end
end
