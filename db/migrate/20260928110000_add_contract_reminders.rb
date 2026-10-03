# Notice-deadline reminders for contracts. Insights gain an optional audience:
# a contract is private to its owner and shares, so a reminder about it must
# not reach the whole household. A null user_id keeps an insight family-wide.
class AddContractReminders < ActiveRecord::Migration[8.1]
  def change
    add_reference :insights, :user, type: :uuid, foreign_key: { on_delete: :cascade }, index: true

    add_column :contracts, :email_reminders, :boolean, null: false, default: true
    # { "<deadline ISO date>" => [ days-before stages already emailed ] }
    add_column :contracts, :notice_reminders_sent, :jsonb, null: false, default: {}
  end
end
