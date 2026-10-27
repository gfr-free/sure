class AddIdTokenHintsForOidcLogout < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :id_token_hint, :text
    add_column :oidc_identities, :pending_id_token_hint, :text
  end
end
