# Fields that only make sense for one kind of contract (an insurance's sum
# insured, a phone plan's number, an energy contract's price guarantee). Kept
# in one jsonb column so a new kind does not need a migration; the model
# validates and types the keys per kind.
class AddDetailsToContracts < ActiveRecord::Migration[8.1]
  def change
    add_column :contracts, :details, :jsonb, null: false, default: {}
  end
end
