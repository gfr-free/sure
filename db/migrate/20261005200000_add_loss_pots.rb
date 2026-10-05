# frozen_string_literal: true

# Loss pots and joint accounts for taxes on returns (liquidity concept,
# decision E21, STEUER.md step S-3 / V-1).
#
# - `loss_pots`: per securities or crypto account (T4), one pot per kind.
#   `stocks` offsets share gains only, `general` offsets every return.
#   `carry_forward` says whether a balance survives the year end (it does
#   not in Austria, for example).
# - `loss_pot_snapshots`: the balance the person copied from a bank
#   statement, with its date. The latest one is the anchor the estimate
#   works from. `source` leaves room for computed or provider balances later
#   (V-2/V-3); this step only writes `manual`.
# - `accounts.tax_joint_user_id` / `tax_owner_share`: a joint account's
#   second person and the owner's share of its returns in percent (T1). Nil
#   share on a joint account means 50/50.
#
# Purely additive: no backfill, existing estimates stay as they are until a
# person enters a pot or marks an account as joint.
class AddLossPots < ActiveRecord::Migration[8.1]
  def change
    create_table :loss_pots, id: :uuid do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.string :kind, null: false
      t.boolean :carry_forward, null: false, default: true

      t.timestamps
    end

    add_index :loss_pots, [ :account_id, :kind ], unique: true
    add_check_constraint :loss_pots, "kind IN ('stocks', 'general')", name: "chk_loss_pots_kind"

    create_table :loss_pot_snapshots, id: :uuid do |t|
      t.references :loss_pot, null: false, foreign_key: { on_delete: :cascade }, type: :uuid, index: false
      t.date :date, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :source, null: false, default: "manual"

      t.timestamps
    end

    add_index :loss_pot_snapshots, [ :loss_pot_id, :date ], unique: true
    add_check_constraint :loss_pot_snapshots, "amount >= 0", name: "chk_loss_pot_snapshots_amount"
    add_check_constraint :loss_pot_snapshots, "source IN ('manual', 'computed', 'provider')",
                         name: "chk_loss_pot_snapshots_source"

    add_reference :accounts, :tax_joint_user, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
    add_column :accounts, :tax_owner_share, :decimal, precision: 5, scale: 2
    add_check_constraint :accounts, "tax_owner_share IS NULL OR (tax_owner_share >= 0 AND tax_owner_share <= 100)",
                         name: "chk_accounts_tax_owner_share"
  end
end
