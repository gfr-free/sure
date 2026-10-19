# The contract register: what the family is bound by (insurance, phone,
# internet, energy, subscriptions, rent), how to get out of it and where the
# paperwork is. See docs/llm-guides/contracts.md.
class CreateContracts < ActiveRecord::Migration[8.1]
  def change
    create_table :contracts, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      # User#reassign_owned_contracts! hands contracts to another member before
      # a user is deleted; the cascade only fires for a family's last user.
      t.references :owner, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, type: :uuid
      t.references :account, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :merchant, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :replaced_by, foreign_key: { to_table: :contracts, on_delete: :nullify }, type: :uuid

      t.string :name, null: false
      t.string :provider_name
      t.string :kind, null: false, default: "other"
      t.string :status, null: false, default: "active"

      # Encrypted when ActiveRecord encryption is configured, so text: the
      # ciphertext is far longer than the number it holds.
      t.text :contract_number
      t.text :customer_number

      t.date :started_on
      t.integer :minimum_term_months
      t.integer :notice_period_value
      t.string :notice_period_unit
      t.string :notice_anchor
      t.integer :renewal_period_months
      t.date :renewal_anchor_on
      t.date :ends_on
      t.date :cancelled_on
      t.date :cancellation_confirmed_on

      t.string :portal_url
      t.string :service_phone
      t.string :service_email
      t.string :claims_phone
      t.jsonb :document_links, null: false, default: []
      t.text :notes

      t.timestamps
    end

    add_index :contracts, [ :family_id, :status ]
    add_check_constraint :contracts, "char_length(name) <= 255", name: "chk_contracts_name_length"
    add_check_constraint :contracts,
                         "kind IN ('insurance','mobile','internet','energy','streaming','software','fitness','membership','rent','other')",
                         name: "chk_contracts_kind"
    add_check_constraint :contracts,
                         "status IN ('active','cancellation_sent','cancelled','ended')",
                         name: "chk_contracts_status"
    add_check_constraint :contracts,
                         "notice_period_unit IS NULL OR notice_period_unit IN ('days','weeks','months')",
                         name: "chk_contracts_notice_period_unit"
    add_check_constraint :contracts,
                         "notice_anchor IS NULL OR notice_anchor IN ('end_of_term','end_of_month','any_day')",
                         name: "chk_contracts_notice_anchor"
    add_check_constraint :contracts,
                         "(minimum_term_months IS NULL OR minimum_term_months >= 0) AND " \
                         "(notice_period_value IS NULL OR notice_period_value >= 0) AND " \
                         "(renewal_period_months IS NULL OR renewal_period_months > 0)",
                         name: "chk_contracts_terms_non_negative"
    add_check_constraint :contracts, "replaced_by_id IS NULL OR replaced_by_id <> id",
                         name: "chk_contracts_not_replaced_by_self"

    create_table :contract_shares, id: :uuid do |t|
      t.references :contract, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :permission, null: false, default: "read_only"

      t.timestamps
    end

    add_index :contract_shares, [ :contract_id, :user_id ], unique: true
    add_check_constraint :contract_shares,
                         "permission IN ('full_control','read_write','read_only')",
                         name: "chk_contract_shares_permission"

    # One row per uploaded file, so each document can carry its own
    # assistant-search opt-in.
    create_table :contract_documents, id: :uuid do |t|
      t.references :contract, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.boolean :ai_searchable, null: false, default: false
      t.references :family_document, foreign_key: { on_delete: :nullify }, type: :uuid

      t.timestamps
    end

    add_reference :recurring_transactions, :contract,
                  foreign_key: { on_delete: :nullify }, type: :uuid, index: true
  end
end
