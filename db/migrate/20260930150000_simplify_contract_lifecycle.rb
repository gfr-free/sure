# Contracts end in one step now (an end date, cancelled or not), and the
# provider is always a merchant. Existing rows are carried over: a recorded
# cancellation becomes an end, and a free-text provider becomes the family
# merchant of that name.
class SimplifyContractLifecycle < ActiveRecord::Migration[8.1]
  def up
    # Providers match merchants the way the app does: trimmed and ignoring
    # case. Only names with no match become new merchants.
    link_providers_to_merchants

    execute <<~SQL
      INSERT INTO merchants (id, type, family_id, name, color, created_at, updated_at)
      SELECT gen_random_uuid(), 'FamilyMerchant', family_id, name, '#6471eb', NOW(), NOW()
      FROM (SELECT DISTINCT ON (family_id, LOWER(BTRIM(provider_name))) family_id, BTRIM(provider_name) AS name
            FROM contracts
            WHERE merchant_id IS NULL AND BTRIM(COALESCE(provider_name, '')) <> '') providers
      ON CONFLICT (family_id, name) WHERE ((type)::text = 'FamilyMerchant'::text) DO NOTHING
    SQL

    link_providers_to_merchants

    # A cancelled contract ends; without a stored end date the cancellation
    # dates stand in, so no reminders start again for it.
    execute <<~SQL
      UPDATE contracts
      SET status = 'ended',
          ends_on = COALESCE(ends_on, cancellation_confirmed_on, cancelled_on, updated_at::date)
      WHERE status IN ('cancellation_sent', 'cancelled')
    SQL
    execute "UPDATE contracts SET ends_on = updated_at::date WHERE status = 'ended' AND ends_on IS NULL"
    execute "DELETE FROM insights WHERE insight_type = 'contract_cancellation_unconfirmed'"

    remove_check_constraint :contracts, name: "chk_contracts_status"
    add_check_constraint :contracts, "status IN ('active','ended')", name: "chk_contracts_status"

    remove_column :contracts, :provider_name
    remove_column :contracts, :cancelled_on
    remove_column :contracts, :cancellation_confirmed_on
  end

  def down
    add_column :contracts, :cancellation_confirmed_on, :date
    add_column :contracts, :cancelled_on, :date
    add_column :contracts, :provider_name, :string

    remove_check_constraint :contracts, name: "chk_contracts_status"
    add_check_constraint :contracts,
                         "status IN ('active','cancellation_sent','cancelled','ended')",
                         name: "chk_contracts_status"
  end

  private

    def link_providers_to_merchants
      execute <<~SQL
        UPDATE contracts SET merchant_id = merchants.id
        FROM merchants
        WHERE contracts.merchant_id IS NULL
          AND merchants.type = 'FamilyMerchant'
          AND merchants.family_id = contracts.family_id
          AND LOWER(merchants.name) = LOWER(BTRIM(contracts.provider_name))
      SQL
    end
end
