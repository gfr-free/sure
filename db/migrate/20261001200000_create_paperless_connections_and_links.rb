# frozen_string_literal: true

class CreatePaperlessConnectionsAndLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :paperless_connection_mode, :string, null: false, default: "per_user"
    add_check_constraint :families, "paperless_connection_mode IN ('per_user', 'family')",
                         name: "chk_families_paperless_connection_mode"

    # One row per user (per_user mode) or one shared row per family (user_id NULL, family mode).
    create_table :paperless_connections, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, type: :uuid, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :base_url, null: false
      t.text :api_token, null: false
      t.boolean :verify_ssl, null: false, default: true
      t.string :server_version
      t.datetime :last_connected_at
      t.text :last_error
      t.timestamps
    end
    add_index :paperless_connections, :family_id
    add_index :paperless_connections, :family_id, unique: true, where: "user_id IS NULL",
              name: "index_paperless_connections_on_family_id_shared"

    # A Paperless document linked to a Sure record. The file stays in Paperless; the
    # cached columns let lists render without a request to Paperless.
    create_table :paperless_links, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :linkable, null: false, type: :uuid, polymorphic: true, index: false
      t.references :paperless_connection, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :document_id, null: false
      t.string :title
      t.date :document_created_on
      t.string :correspondent_name
      t.string :mime_type
      t.timestamps
    end
    add_index :paperless_links, %i[linkable_type linkable_id document_id], unique: true,
              name: "index_paperless_links_on_linkable_and_document"
  end
end
