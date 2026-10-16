# Lets a series on a manual account post its own entry on each due date.
# `auto_post_from` stops the first run from backfilling the past, and
# `auto_posted_at` on the occurrence guarantees each date posts at most once,
# even after the user deletes the posted entry.
class AddAutoPostToRecurringTransactions < ActiveRecord::Migration[8.1]
  OLD_SOURCES = %w[auto_matched user_confirmed user_created].freeze
  NEW_SOURCES = (OLD_SOURCES + %w[auto_posted]).freeze

  def up
    add_column :recurring_transactions, :auto_post, :boolean, null: false, default: false
    add_column :recurring_transactions, :auto_post_from, :date
    add_column :recurring_occurrences, :auto_posted_at, :datetime

    replace_source_constraint(NEW_SOURCES)
  end

  def down
    # Keep the payments: an auto-posted allocation is still a real payment,
    # so it survives the rollback as a user-confirmed one.
    execute <<~SQL
      UPDATE recurring_allocations SET source = 'user_confirmed' WHERE source = 'auto_posted'
    SQL

    replace_source_constraint(OLD_SOURCES)

    remove_column :recurring_occurrences, :auto_posted_at
    remove_column :recurring_transactions, :auto_post_from
    remove_column :recurring_transactions, :auto_post
  end

  private
    def replace_source_constraint(sources)
      remove_check_constraint :recurring_allocations, name: "chk_recurring_allocations_source"
      add_check_constraint :recurring_allocations,
        "source IN (#{sources.map { |s| connection.quote(s) }.join(', ')})",
        name: "chk_recurring_allocations_source"
    end
end
