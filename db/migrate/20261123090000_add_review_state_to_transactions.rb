class AddReviewStateToTransactions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # The manual review mark on a transaction: nil (open), "flagged" or
  # "reviewed", plus when and by whom it was last set. Every row starts
  # empty, so the constraints are added without scanning the table.
  def change
    add_column :transactions, :review_state, :string
    add_column :transactions, :review_state_changed_at, :datetime
    add_column :transactions, :review_state_changed_by_id, :uuid

    add_check_constraint :transactions, "review_state IN ('flagged', 'reviewed')",
      name: "chk_transactions_review_state", validate: false
    add_foreign_key :transactions, :users, column: :review_state_changed_by_id,
      on_delete: :nullify, validate: false

    add_index :transactions, :review_state,
      where: "review_state IS NOT NULL", algorithm: :concurrently
    add_index :transactions, :review_state_changed_by_id,
      where: "review_state_changed_by_id IS NOT NULL", algorithm: :concurrently
  end
end
