# frozen_string_literal: true

# Release reminders for locked money (decision E5).
#
# - accounts.grace_days: days after an automatic renewal during which the
#   deposit can still be cancelled (common for term deposits). Shown on the
#   account and in the renewal reminder; it does not change availability.
# - account_release_notices: one row per e-mail reminder sent, so the daily
#   job never mails the same person about the same release twice. Insights
#   need no table: their dedup_key already does this.
class AddAccountReleaseNotices < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :grace_days, :integer
    add_check_constraint :accounts, "grace_days IS NULL OR grace_days >= 0", name: "chk_accounts_grace_days"

    create_table :account_release_notices, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :kind, null: false
      t.date :release_on, null: false

      t.timestamps
    end

    add_index :account_release_notices, [ :account_id, :user_id, :kind, :release_on ],
              unique: true, name: "index_account_release_notices_uniqueness"
  end
end
