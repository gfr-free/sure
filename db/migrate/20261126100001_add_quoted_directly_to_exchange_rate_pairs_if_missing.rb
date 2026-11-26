# Production marked 20261118120000 as run for the counterparty migration, which
# shared that version with main's AddQuotedDirectlyToExchangeRatePairs, so Rails
# never runs main's migration there. This adds the column where it is missing.
class AddQuotedDirectlyToExchangeRatePairsIfMissing < ActiveRecord::Migration[8.1]
  def change
    add_column :exchange_rate_pairs, :quoted_directly, :boolean, default: false, null: false, if_not_exists: true
  end
end
